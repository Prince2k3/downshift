import Foundation
import DownshiftCore

/// The per-user LaunchAgent that keeps `dshift serve` running, so the proxy is up before the
/// apps start and comes back if it exits. `~/Library/LaunchAgents/dev.downshift.serve.plist`,
/// loaded into the `gui/<uid>` domain, logging to `~/Library/Logs/downshift/serve.log`.
public struct LaunchAgent: Sendable {
    public static let label = "dev.downshift.serve"

    /// Runs `launchctl` with the given arguments and returns its exit status and combined output.
    public typealias Launchctl = @Sendable ([String]) -> (status: Int32, output: String)

    public var plistURL: URL
    public var logURL: URL
    /// Where development builds are copied before launchd runs them (see `stage`).
    public var stagingDirectory: URL
    var domain: String
    var launchctl: Launchctl
    var retryDelay: @Sendable () -> Void

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                uid: uid_t = getuid(),
                launchctl: @escaping Launchctl = LaunchAgent.runLaunchctl,
                retryDelay: @escaping @Sendable () -> Void = { usleep(250_000) }) {
        plistURL = home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
        logURL = home.appendingPathComponent("Library/Logs/downshift/serve.log")
        stagingDirectory = home.appendingPathComponent("Library/Application Support/downshift/bin")
        domain = "gui/\(uid)"
        self.launchctl = launchctl
        self.retryDelay = retryDelay
    }

    var service: String { "\(domain)/\(Self.label)" }

    // MARK: plist

    public static func programArguments(executable: String, port: Int) -> [String] {
        [executable, "serve", "run", "--port", String(port)]
    }

    /// `KeepAlive` restarts the proxy whenever it exits (a crash, or a port clash that clears
    /// later); `ThrottleInterval` keeps a proxy that can't start from spinning.
    public static func plist(executable: String, port: Int, log: URL) throws -> Data {
        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments(executable: executable, port: port),
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    /// The path to put in the plist: the path dshift was invoked by, made absolute but with
    /// symlinks kept, so a Homebrew install keeps pointing at `/opt/homebrew/bin/dshift` across
    /// upgrades instead of a versioned Cellar path that `brew cleanup` deletes.
    public static func executablePath(invokedAs argument0: String,
                                      currentDirectory: String = FileManager.default.currentDirectoryPath,
                                      searchPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        if argument0.contains("/") {
            let url = argument0.hasPrefix("/")
                ? URL(fileURLWithPath: argument0)
                : URL(fileURLWithPath: currentDirectory, isDirectory: true).appendingPathComponent(argument0)
            return url.standardizedFileURL.path
        }
        for directory in (searchPath ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(argument0).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: staging development builds

    /// A SwiftPM build directory. Homebrew and Mint installs are run in place.
    public static func isDevelopmentBuild(_ executable: String) -> Bool {
        executable.contains("/.build/")
    }

    /// Copies a development build out of the source tree, which usually sits under a
    /// TCC-protected folder such as ~/Documents: launchd's first launch of a binary there
    /// stalls on a privacy check nobody can answer. The copy is written to a new file and
    /// renamed into place, so a running proxy keeps its old inode and the kernel never sees a
    /// signed binary modified in place. Returns the copy's path and whether its bytes changed.
    public func stage(executable: String) throws -> (path: String, changed: Bool) {
        let source = URL(fileURLWithPath: executable)
        let destination = stagingDirectory.appendingPathComponent("dshift")
        let data: Data
        do { data = try Data(contentsOf: source) } catch {
            throw AppsError("can't read \(executable): \(error.localizedDescription)")
        }
        if (try? Data(contentsOf: destination)) == data { return (destination.path, false) }
        do {
            try AtomicFile.privateDirectory(stagingDirectory)
            try AtomicFile.write(data, to: destination, permissions: 0o755)
        } catch {
            throw AppsError("can't copy the development build to \(destination.path): \(error)")
        }
        return (destination.path, true)
    }

    // MARK: install / uninstall

    public enum InstallOutcome: Sendable, Equatable {
        case installed
        /// A different plist (other port or executable) was replaced and the agent reloaded.
        case replaced
        case alreadyInstalled
    }

    /// Installs and (re)loads the agent. A development build is staged first (see `stage`),
    /// and a changed copy reloads the agent even when the plist is unchanged.
    public func install(executable: String, port: Int) throws -> InstallOutcome {
        var executable = executable
        var binaryChanged = false
        if Self.isDevelopmentBuild(executable) {
            (executable, binaryChanged) = try stage(executable: executable)
        }
        let data = try Self.plist(executable: executable, port: port, log: logURL)
        let existing = try? Data(contentsOf: plistURL)
        if existing == data, !binaryChanged, isLoaded { return .alreadyInstalled }

        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try ManagedFile.write(data, to: plistURL, newFilePermissions: 0o644)

        // Unload whatever is loaded (an older plist, or this one), clear a `launchctl disable`
        // override, then load. bootout returns before the old job is fully gone, so bootstrap
        // is retried briefly while launchd still reports it busy.
        _ = launchctl(["bootout", service])
        _ = launchctl(["enable", service])
        var result = launchctl(["bootstrap", domain, plistURL.path])
        for _ in 0..<8 where result.status != 0 {
            retryDelay()
            result = launchctl(["bootstrap", domain, plistURL.path])
        }
        guard result.status == 0 else {
            throw AppsError("launchctl bootstrap \(domain) \(plistURL.path) failed (\(result.status)): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return existing == nil ? .installed : .replaced
    }

    /// Stops the agent and removes its plist and any staged build. Returns false if there was
    /// nothing to remove.
    @discardableResult
    public func uninstall() throws -> Bool {
        let loaded = isLoaded
        if loaded { _ = launchctl(["bootout", service]) }
        try? FileManager.default.removeItem(at: stagingDirectory)
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return loaded }
        try FileManager.default.removeItem(at: plistURL)
        return true
    }

    /// Restarts a loaded proxy so it rereads its environment (after `dshift setup`). False when
    /// it isn't loaded or launchd refused.
    @discardableResult
    public func restart() -> Bool {
        guard isLoaded else { return false }
        return launchctl(["kickstart", "-k", service]).status == 0
    }

    // MARK: status

    public struct Status: Sendable, Equatable {
        public var installed: Bool
        public var loaded: Bool
        public var pid: Int?
        /// The `--port` in the installed plist.
        public var port: Int?
        public var executable: String?
    }

    public var isLoaded: Bool { launchctl(["print", service]).status == 0 }

    public func status() -> Status {
        var status = Status(installed: false, loaded: false)
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            status.installed = true
            let arguments = plist["ProgramArguments"] as? [String] ?? []
            status.executable = arguments.first
            if let index = arguments.firstIndex(of: "--port"), index + 1 < arguments.count {
                status.port = Int(arguments[index + 1])
            }
        }
        let printed = launchctl(["print", service])
        if printed.status == 0 {
            status.loaded = true
            status.pid = Self.pid(fromPrint: printed.output)
        }
        return status
    }

    /// Reads `pid = 123` from `launchctl print` output; absent while the job isn't running.
    static func pid(fromPrint output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "pid", let pid = Int(parts[1]) { return pid }
        }
        return nil
    }

    public static let runLaunchctl: Launchctl = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
