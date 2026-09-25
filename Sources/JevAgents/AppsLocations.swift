import Foundation

/// The agent apps whose configuration `jev apps` manages.
public enum ManagedApp: String, Sendable, CaseIterable, Codable {
    /// The `claude` CLI, via `~/.claude/settings.json`. The Claude app's Code tab sets its own
    /// `ANTHROPIC_BASE_URL` for each session, which overrides that file, so it isn't covered.
    case claude
    /// The Codex app (inside ChatGPT.app) and the `codex` CLI; both read `~/.codex/config.toml`.
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code CLI"
        case .codex: "Codex (app + CLI)"
        }
    }
}

/// Where the managed files and jev's own state live. Honours `CLAUDE_CONFIG_DIR` and
/// `CODEX_HOME` the same way the agents do, so jev edits the file the agent actually reads.
public struct AppsLocations: Sendable {
    public var claudeSettings: URL
    public var codexConfig: URL
    /// Holds `apps.json` (what jev changed) and `backups/`.
    public var stateDirectory: URL

    public init(claudeSettings: URL, codexConfig: URL, stateDirectory: URL) {
        self.claudeSettings = claudeSettings
        self.codexConfig = codexConfig
        self.stateDirectory = stateDirectory
    }

    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppsLocations {
        func directory(_ variable: String, default path: String) -> URL {
            if let value = environment[variable], !value.isEmpty { return URL(fileURLWithPath: value, isDirectory: true) }
            return home.appendingPathComponent(path, isDirectory: true)
        }
        #if os(macOS)
        let state = home.appendingPathComponent("Library/Application Support/jev", isDirectory: true)
        #else
        let state = directory("XDG_STATE_HOME", default: ".local/state").appendingPathComponent("jev", isDirectory: true)
        #endif
        return AppsLocations(
            claudeSettings: directory("CLAUDE_CONFIG_DIR", default: ".claude").appendingPathComponent("settings.json"),
            codexConfig: directory("CODEX_HOME", default: ".codex").appendingPathComponent("config.toml"),
            stateDirectory: state)
    }

    public func file(for app: ManagedApp) -> URL {
        switch app {
        case .claude: claudeSettings
        case .codex: codexConfig
        }
    }

    public var stateFile: URL { stateDirectory.appendingPathComponent("apps.json") }
    public var backupsDirectory: URL { stateDirectory.appendingPathComponent("backups", isDirectory: true) }
}
