import Foundation

/// Finds the agent CLIs: `PATH` first, then the copies the desktop apps ship (plan §6a), so
/// `dshift codex` works for someone who only installed ChatGPT.app.
public struct ExecutableResolver: Sendable {
    public var path: String
    public var home: URL
    public var applications: [URL]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                applications: [URL]? = nil) {
        self.path = environment["PATH"] ?? ""
        self.home = home
        self.applications = applications ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    public enum Source: String, Sendable {
        case path = "PATH"
        case app = "app-embedded"
    }

    public struct Found: Sendable, Equatable {
        public var path: String
        public var source: Source
    }

    public func onPath(_ name: String) -> String? {
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let file = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: file) { return file }
        }
        return nil
    }

    public func claude() -> Found? {
        if let file = onPath("claude") { return Found(path: file, source: .path) }
        return embeddedClaude().map { Found(path: $0, source: .app) }
    }

    public func codex() -> Found? {
        if let file = onPath("codex") { return Found(path: file, source: .path) }
        return embeddedCodex().map { Found(path: $0, source: .app) }
    }

    /// The Claude app downloads Claude Code into one folder per version; the newest wins.
    public func embeddedClaude() -> String? {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for version in versions.sorted(by: { Self.versionLess($1, $0) }) {
            let file = root.appendingPathComponent(version).appendingPathComponent("claude.app/Contents/MacOS/claude").path
            if FileManager.default.isExecutableFile(atPath: file) { return file }
        }
        return nil
    }

    /// ChatGPT.app (and a standalone Codex.app, if there is one) carry the Codex CLI.
    public func embeddedCodex() -> String? {
        for folder in applications {
            for app in ["ChatGPT.app", "Codex.app"] {
                let file = folder.appendingPathComponent(app).appendingPathComponent("Contents/Resources/codex").path
                if FileManager.default.isExecutableFile(atPath: file) { return file }
            }
        }
        return nil
    }

    /// Dotted numeric comparison: 2.1.100 sorts after 2.1.99.
    static func versionLess(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }
}
