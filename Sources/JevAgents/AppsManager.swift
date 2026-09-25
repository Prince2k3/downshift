import Foundation
import JevCore

/// `jev apps enable/disable/status`: points the Claude and Codex apps at the local proxy by
/// editing the config files they read at startup, reversibly.
///
/// Every write is preceded by a backup. `apps.json` records the backup, the hash of the file
/// right after enabling, and what was replaced. On disable, if nobody touched the file since
/// (hash matches) the backup is restored byte for byte; otherwise only jev's entries are
/// removed so the user's and the app's own later changes survive.
public struct AppsManager: Sendable {
    public static let defaultPort = 47821

    public var locations: AppsLocations
    var now: @Sendable () -> Date

    public init(locations: AppsLocations = .standard(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.locations = locations
        self.now = now
    }

    /// Both apps go through one port: Claude at the root (`/v1/messages`), Codex under `/codex`
    /// (`/codex/responses`), so the proxy can tell them apart without guessing from paths.
    public static func baseURL(for app: ManagedApp, port: Int) -> String {
        switch app {
        case .claude: "http://127.0.0.1:\(port)"
        case .codex: "http://127.0.0.1:\(port)/codex"
        }
    }

    public enum EnableOutcome: Sendable, Equatable {
        case enabled(backup: URL?)
        case alreadyEnabled
    }

    public enum DisableOutcome: Sendable, Equatable {
        /// Nothing changed since enabling, so the original bytes were put back.
        case restoredBackup(URL)
        /// The file changed since enabling; only jev's entries were removed.
        case removedEntries(untouched: [String])
        /// The file did not exist before enabling and was deleted again.
        case removedFile
        case notEnabled
    }

    public struct Status: Sendable {
        public var app: ManagedApp
        public var file: URL
        public var enabled: Bool
        public var baseURL: String?
        public var port: Int?
        public var proxyListening: Bool?
        /// Codex only: whether `model_provider = "jev"` makes routing the default.
        public var defaultProvider: Bool?
        public var backup: URL?
    }

    // MARK: enable

    @discardableResult
    public func enable(_ app: ManagedApp, port: Int = defaultPort, codexDefaultProvider: Bool = true) throws -> EnableOutcome {
        guard (1...65535).contains(port) else { throw AppsError("port must be 1–65535") }
        var state = try loadState()
        let file = locations.file(for: app)
        let original = try ManagedFile.read(file)
        let baseURL = Self.baseURL(for: app, port: port)

        if let record = state[app.rawValue]?.objectValue {
            if record["baseURL"]?.stringValue == baseURL, isEnabled(app, data: original, baseURL: baseURL) {
                return .alreadyEnabled
            }
            throw AppsError("\(app.rawValue) is already enabled with different settings; run `jev apps disable --\(app.rawValue)` first")
        }

        let updated: Data
        var record: JSONObject = ["baseURL": .string(baseURL), "port": .number(port), "fileExisted": .bool(original != nil)]
        switch app {
        case .claude:
            let (data, previous) = try ClaudeSettingsEdit.enable(original, baseURL: baseURL)
            updated = data
            record["envExisted"] = .bool(previous.envExisted)
            record["previousEnv"] = .object(JSONObject(previous.env.sorted { $0.key < $1.key }.map {
                ($0.key, $0.value.map(JSONValue.string) ?? .null)
            }))
        case .codex:
            let (data, previous) = try CodexConfigEdit.enable(original, baseURL: baseURL, defaultProvider: codexDefaultProvider)
            updated = data
            record["addedFinalNewline"] = .bool(previous.addedFinalNewline)
            record["defaultProvider"] = .bool(codexDefaultProvider)
        }

        var backup: URL?
        if let original {
            backup = try ManagedFile.backup(original, of: file, app: app, into: locations.backupsDirectory, at: now())
            record["backup"] = .string(backup!.path)
        }
        try ManagedFile.write(updated, to: file)
        record["enabledSHA256"] = .string(ManagedFile.sha256(updated))
        state[app.rawValue] = .object(record)
        try saveState(state)
        return .enabled(backup: backup)
    }

    // MARK: disable

    @discardableResult
    public func disable(_ app: ManagedApp) throws -> DisableOutcome {
        var state = try loadState()
        let file = locations.file(for: app)
        let current = try ManagedFile.read(file)

        guard let record = state[app.rawValue]?.objectValue else {
            // No record, but a jev block may still be there (state deleted, or edited by hand).
            guard let current, isEnabled(app, data: current, baseURL: nil) else { return .notEnabled }
            return try removeEntries(app, from: current, file: file, record: [:], state: &state)
        }
        guard let current else {
            state[app.rawValue] = nil
            try saveState(state)
            return .notEnabled
        }

        if ManagedFile.sha256(current) == record["enabledSHA256"]?.stringValue {
            if record["fileExisted"]?.boolValue == false {
                try ManagedFile.remove(file)
                state[app.rawValue] = nil
                try saveState(state)
                return .removedFile
            }
            if let path = record["backup"]?.stringValue, let original = try ManagedFile.read(URL(fileURLWithPath: path)) {
                try ManagedFile.write(original, to: file)
                state[app.rawValue] = nil
                try saveState(state)
                return .restoredBackup(URL(fileURLWithPath: path))
            }
        }
        return try removeEntries(app, from: current, file: file, record: record, state: &state)
    }

    private func removeEntries(_ app: ManagedApp, from current: Data, file: URL, record: JSONObject,
                               state: inout JSONObject) throws -> DisableOutcome {
        _ = try ManagedFile.backup(current, of: file, app: app, into: locations.backupsDirectory, at: now())
        let updated: Data
        var untouched: [String] = []
        switch app {
        case .claude:
            let baseURL = record["baseURL"]?.stringValue ?? ClaudeSettingsEdit.isEnabled(current) ?? ""
            var previousEnv: [String: String?] = [:]
            for entry in record["previousEnv"]?.objectValue?.entries ?? [] {
                previousEnv[entry.key] = .some(entry.value.stringValue)
            }
            let previous = ClaudeSettingsEdit.Previous(env: previousEnv, envExisted: record["envExisted"]?.boolValue ?? true)
            (updated, untouched) = try ClaudeSettingsEdit.disable(current, baseURL: baseURL, previous: previous)
        case .codex:
            let previous = CodexConfigEdit.Previous(addedFinalNewline: record["addedFinalNewline"]?.boolValue ?? false)
            updated = try CodexConfigEdit.disable(current, previous: previous)
        }
        try ManagedFile.write(updated, to: file)
        state[app.rawValue] = nil
        try saveState(state)
        return .removedEntries(untouched: untouched)
    }

    // MARK: status

    public func status() throws -> [Status] {
        let state = try loadState()
        return try ManagedApp.allCases.map { app in
            let file = locations.file(for: app)
            let data = try ManagedFile.read(file)
            let record = state[app.rawValue]?.objectValue
            let enabled = isEnabled(app, data: data, baseURL: nil)
            let baseURL = record?["baseURL"]?.stringValue ?? (app == .claude ? ClaudeSettingsEdit.isEnabled(data) : nil)
            let port = record?["port"]?.intValue ?? baseURL.flatMap { URLComponents(string: $0)?.port }
            return Status(
                app: app, file: file, enabled: enabled, baseURL: enabled ? baseURL : nil, port: enabled ? port : nil,
                proxyListening: enabled ? port.map { ProxyProbe.isListening(port: $0) } : nil,
                defaultProvider: app == .codex && enabled ? CodexConfigEdit.hasDefaultProvider(data) : nil,
                backup: record?["backup"]?.stringValue.map { URL(fileURLWithPath: $0) })
        }
    }

    // MARK: helpers

    func isEnabled(_ app: ManagedApp, data: Data?, baseURL: String?) -> Bool {
        switch app {
        case .claude: ClaudeSettingsEdit.isEnabled(data, baseURL: baseURL) != nil
        case .codex: CodexConfigEdit.isEnabled(data)
        }
    }

    func loadState() throws -> JSONObject {
        guard let data = try ManagedFile.read(locations.stateFile) else { return JSONObject() }
        guard let object = try? JSONValue.parse(data).objectValue else {
            throw AppsError("\(locations.stateFile.path) is corrupt; move it aside and re-run")
        }
        return object
    }

    func saveState(_ state: JSONObject) throws {
        try FileManager.default.createDirectory(at: locations.stateDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var bytes = JSONValue.object(state).serialized(indent: 2)
        bytes.append(0x0A)
        try ManagedFile.write(Data(bytes), to: locations.stateFile, newFilePermissions: 0o600)
    }
}

/// Checks whether something accepts TCP connections on 127.0.0.1:port.
public enum ProxyProbe {
    public static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
