import Foundation

/// A dotenv parser matching what Node's `process.loadEnvFile` accepted, so existing
/// `~/.jev-router.env` files keep working:
/// - `KEY=value`, with an optional `export ` prefix; blank lines and `#` comments are skipped.
/// - Unquoted values are trimmed, and ` #` starts an inline comment.
/// - `'…'`, `"…"` and `` `…` `` quotes may span lines; only double quotes expand `\n`.
/// - Later duplicates win within one file.
public enum EnvFile {
    public static func parse(_ text: String) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let raw = lines.popFirst() {
            var line = raw.drop { $0 == " " || $0 == "\t" }
            if line.isEmpty || line.first == "#" { continue }
            if line.hasPrefix("export ") { line = line.dropFirst("export ".count).drop { $0 == " " } }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }) else { continue }
            var rest = Substring(line[line.index(after: equals)...].drop { $0 == " " || $0 == "\t" })

            let value: String
            if let quote = rest.first, quote == "\"" || quote == "'" || quote == "`" {
                rest = rest.dropFirst()
                var body = String(rest)
                // Multi-line: keep consuming lines until one contains the closing quote.
                while !body.contains(quote), let next = lines.popFirst() { body += "\n" + next }
                if let close = body.firstIndex(of: quote) {
                    body = String(body[..<close])
                } else {
                    // No closing quote anywhere: Node keeps the opening quote and the first line only.
                    body = String(quote) + (body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "")
                }
                value = quote == "\"" ? body.replacingOccurrences(of: "\\n", with: "\n") : body
            } else {
                if let comment = rest.range(of: " #") ?? rest.range(of: "\t#") { rest = rest[..<comment.lowerBound] }
                value = rest.trimmingCharacters(in: .whitespaces)
            }
            result.removeAll { $0.key == key }
            result.append((key, value))
        }
        return result
    }
}

/// The environment dshift runs with, where the first place a key is set wins:
/// process env → the keychain (`dshift setup`) → `./.env` → `~/.downshift.env` → `~/.jev-router.env` →
/// `~/.jev-claude.env` (legacy). The env files keep the Node launchers' precedence among themselves.
/// Variables from before the rename (`JEV_HOST`, …) still count: in each place, `JEV_X` is read as
/// `DSHIFT_X` unless that place also sets `DSHIFT_X`.
public struct DownshiftEnvironment: Sendable {
    public var values: [String: String]
    /// The env files that existed and were read, in precedence order.
    public var loadedFiles: [URL]
    /// Keys whose value came from the keychain.
    public var storedKeys: Set<String>
    /// Why the keychain couldn't be read, if it couldn't (the environment still loads).
    public var credentialProblem: String?

    public init(values: [String: String], loadedFiles: [URL] = [], storedKeys: Set<String> = [], credentialProblem: String? = nil) {
        self.values = values
        self.loadedFiles = loadedFiles
        self.storedKeys = storedKeys
        self.credentialProblem = credentialProblem
    }

    public static func files(currentDirectory: URL, home: URL) -> [URL] {
        [currentDirectory.appendingPathComponent(".env"),
         home.appendingPathComponent(".downshift.env"),
         home.appendingPathComponent(".jev-router.env"),
         home.appendingPathComponent(".jev-claude.env")]
    }

    public static func load(
        process: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        credentials: CredentialStore? = .keychain
    ) -> DownshiftEnvironment {
        let stored = credentials.map { store in Result { try store.read() } } ?? .success([:])
        return load(process: process, currentDirectory: currentDirectory, home: home, stored: stored)
    }

    static func load(process: [String: String], currentDirectory: URL, home: URL,
                     stored: Result<[String: String], any Error>) -> DownshiftEnvironment {
        var values = Dictionary(renamingLegacy(process), uniquingKeysWith: { first, _ in first })
        var storedKeys: Set<String> = []
        var problem: String?
        switch stored {
        case .success(let stored):
            for (key, value) in renamingLegacy(stored) where values[key] == nil {
                values[key] = value
                storedKeys.insert(key)
            }
        case .failure(let error):
            problem = "\(error)"
        }
        var loaded: [URL] = []
        for file in files(currentDirectory: currentDirectory, home: home) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            loaded.append(file)
            for (key, value) in renamingLegacy(EnvFile.parse(text)) where values[key] == nil { values[key] = value }
        }
        return DownshiftEnvironment(values: values, loadedFiles: loaded, storedKeys: storedKeys, credentialProblem: problem)
    }

    /// One place's variables with the pre-rename `JEV_` prefix read as `DSHIFT_`; a `DSHIFT_`
    /// variable set in the same place wins. (`*_JEV` suffixes name the Jev AI and stay as they are.)
    static func renamingLegacy(_ pairs: some Sequence<(key: String, value: String)>) -> [(key: String, value: String)] {
        let pairs = Array(pairs)
        let current = Set(pairs.map(\.key))
        return pairs.compactMap { pair in
            guard pair.key.hasPrefix("JEV_") else { return pair }
            let renamed = "DSHIFT_" + pair.key.dropFirst("JEV_".count)
            return current.contains(renamed) ? nil : (renamed, pair.value)
        }
    }

    public subscript(key: String) -> String? { values[key] }

    /// A variable that counts as set: present and not empty.
    public func isSet(_ key: String) -> Bool { !(values[key] ?? "").isEmpty }
}

/// dshift's own settings, each read from an environment variable.
public struct DownshiftSettings: Sendable {
    public var environment: DownshiftEnvironment

    public init(environment: DownshiftEnvironment) { self.environment = environment }

    /// The Jev host to use (`cloudflare`, `vercel`, `openrouter`, …); nil picks the default.
    public var host: String? { environment["DSHIFT_HOST"].flatMap { $0.isEmpty ? nil : $0 } }
    /// Overrides the Jev model id on the host.
    public var jevModel: String? { environment["DSHIFT_MODEL"].flatMap { $0.isEmpty ? nil : $0 } }
    /// The long tier (Fable, Astra) bills extra usage credits, so it has to be allowed.
    public var allowLong: Bool { environment["DSHIFT_ALLOW_FABLE"] == "1" }
    public var debug: Bool { environment.isSet("DSHIFT_DEBUG") }
    /// Directory for request/response dumps.
    public var dumpDirectory: String? { environment["DSHIFT_DUMP"].flatMap { $0.isEmpty ? nil : $0 } }
    public var statusLine: Bool { !environment.isSet("DSHIFT_NO_STATUSLINE") }

    public var availableTiers: [Tier] { Tier.available(allowLong: allowLong) }

    public func codexModel(_ tier: Tier) -> String { CodexModel.id(for: tier, environment: environment.values) }
}
