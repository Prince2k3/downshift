import Foundation
import Testing
@testable import DownshiftAgents
@testable import DownshiftCore

/// A throwaway home: settings.json, config.toml and the dshift state directory under one temp dir.
struct Sandbox {
    let root: URL
    let manager: AppsManager

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dshift-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manager = AppsManager(locations: AppsLocations(
            claudeSettings: root.appendingPathComponent(".claude/settings.json"),
            codexConfig: root.appendingPathComponent(".codex/config.toml"),
            stateDirectory: root.appendingPathComponent("state")))
    }

    func url(_ app: ManagedApp) -> URL { manager.locations.file(for: app) }

    func write(_ app: ManagedApp, _ text: String) throws {
        let url = url(app)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ app: ManagedApp) throws -> String { String(decoding: try Data(contentsOf: url(app)), as: UTF8.self) }
    func exists(_ app: ManagedApp) -> Bool { FileManager.default.fileExists(atPath: url(app).path) }
}

/// Shaped like a real ~/.codex/config.toml: top-level keys including a multi-line array, then tables.
let codexFixture = """
    model = "gpt-5-codex"
    model_reasoning_effort = "high"
    notify = [
      "bash",
      "-lc",
      "afplay /System/Library/Sounds/Glass.aiff", # [not a table]
    ]

    [projects."/Users/me/code"]
    trust_level = "trusted"

    [mcp_servers.docs]
    command = "npx"
    args = ["-y", "docs-mcp"]

    """

let claudeFixture = """
    {
      "permissions": {
        "allow": [
          "Bash(ls:*)"
        ],
        "deny": []
      },
      "env": {
        "DISABLE_TELEMETRY": "1"
      },
      "model": "opus"
    }

    """

@Suite struct AppsManagerTests {
    @Test(arguments: [ManagedApp.claude, .codex])
    func enableThenDisableIsByteIdentical(app: ManagedApp) throws {
        let box = try Sandbox()
        let original = app == .claude ? claudeFixture : codexFixture
        try box.write(app, original)

        guard case .enabled(let backup?) = try box.manager.enable(app) else { Issue.record("no backup"); return }
        #expect(try Data(contentsOf: backup) == Data(original.utf8))
        #expect(try box.read(app) != original)
        #expect(try box.manager.enable(app) == .alreadyEnabled)

        guard case .restoredBackup = try box.manager.disable(app) else { Issue.record("expected restore"); return }
        #expect(try box.read(app) == original)
        #expect(try box.manager.disable(app) == .notEnabled)
    }

    @Test func claudeEditKeepsOrderAndIndent() throws {
        let box = try Sandbox()
        try box.write(.claude, claudeFixture)
        _ = try box.manager.enable(.claude)
        let expected = claudeFixture.replacingOccurrences(
            of: "\"DISABLE_TELEMETRY\": \"1\"\n",
            with: "\"DISABLE_TELEMETRY\": \"1\",\n" + ClaudeSettingsEdit.managedEnv(baseURL: "http://127.0.0.1:47821")
                .map { "    \"\($0.0)\": \"\($0.1)\"" }.joined(separator: ",\n") + "\n")
        #expect(try box.read(.claude).contains(#""ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Dynamic (Downshift)""#))
        #expect(try box.read(.claude) == expected)
    }

    @Test func codexEditPutsProfileBeforeFirstTable() throws {
        let box = try Sandbox()
        try box.write(.codex, codexFixture)
        _ = try box.manager.enable(.codex)
        let lines = try box.read(.codex).components(separatedBy: "\n")
        let profile = try #require(lines.firstIndex(of: "model_provider = \"downshift\""))
        let firstTable = try #require(lines.firstIndex { $0.hasPrefix("[") })
        #expect(profile < firstTable)
        #expect(profile > (lines.firstIndex(of: "]") ?? 0), "must not land inside the notify array")
        #expect(lines.contains("base_url = \"http://127.0.0.1:47821/codex\""))
        #expect(CodexConfigEdit.isEnabled(try Data(contentsOf: box.url(.codex))))
    }

    /// codex 0.155 refuses to load a config with a top-level `profile`, which blanked the app.
    @Test func neverWritesLegacyProfileKeys() throws {
        let box = try Sandbox()
        try box.write(.codex, codexFixture)
        _ = try box.manager.enable(.codex)
        let text = try box.read(.codex)
        #expect(!text.contains("profile = ") && !text.contains("[profiles."))
    }

    @Test func noDefaultProviderLeavesTopLevelAlone() throws {
        let box = try Sandbox()
        try box.write(.codex, codexFixture)
        _ = try box.manager.enable(.codex, codexDefaultProvider: false)
        let text = try box.read(.codex)
        #expect(!text.contains("model_provider = \"downshift\""))
        #expect(text.hasPrefix(codexFixture))
    }

    @Test(arguments: [ManagedApp.claude, .codex])
    func missingFileIsCreatedThenRemoved(app: ManagedApp) throws {
        let box = try Sandbox()
        #expect(try box.manager.enable(app) == .enabled(backup: nil))
        #expect(box.exists(app))
        #expect(try box.manager.disable(app) == .removedFile)
        #expect(!box.exists(app))
    }

    @Test func claudeDisableAfterOutsideEditIsSurgical() throws {
        let box = try Sandbox()
        try box.write(.claude, claudeFixture)
        _ = try box.manager.enable(.claude)
        // The app rewrites settings.json while dshift is enabled.
        try box.write(.claude, try box.read(.claude).replacingOccurrences(of: "\"opus\"", with: "\"sonnet\""))
        guard case .removedEntries(let untouched) = try box.manager.disable(.claude) else { Issue.record("expected surgical"); return }
        #expect(untouched.isEmpty)
        #expect(try box.read(.claude) == claudeFixture.replacingOccurrences(of: "\"opus\"", with: "\"sonnet\""))
    }

    @Test func claudePreviousValueIsRestoredAndChangedValueKept() throws {
        let box = try Sandbox()
        try box.write(.claude, #"{"env":{"ANTHROPIC_BASE_URL":"https://gateway.example"}}"#)
        _ = try box.manager.enable(.claude)
        #expect(try box.read(.claude).contains("127.0.0.1:47821"))
        try box.write(.claude, #"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:47821"},"x":1}"#)
        _ = try box.manager.disable(.claude)
        let restored = try box.read(.claude)
        #expect(restored == #"{"env":{"ANTHROPIC_BASE_URL":"https://gateway.example"},"x":1}"#, "\(restored)")

        _ = try box.manager.enable(.claude)
        try box.write(.claude, #"{"env":{"ANTHROPIC_BASE_URL":"https://mine.example"},"x":2}"#)
        // The user replaced dshift's value, so disable leaves it alone and says so.
        #expect(try box.manager.disable(.claude) == .removedEntries(untouched: ["ANTHROPIC_BASE_URL"]))
        #expect(try box.read(.claude) == #"{"env":{"ANTHROPIC_BASE_URL":"https://mine.example"},"x":2}"#)
    }

    @Test func codexDisableAfterOutsideEditIsSurgical() throws {
        let box = try Sandbox()
        try box.write(.codex, codexFixture)
        _ = try box.manager.enable(.codex)
        try box.write(.codex, try box.read(.codex) + "[tui]\nnotifications = true\n")
        guard case .removedEntries = try box.manager.disable(.codex) else { Issue.record("expected surgical"); return }
        #expect(try box.read(.codex) == codexFixture + "[tui]\nnotifications = true\n")
    }

    @Test func codexConflictsAreRefused() throws {
        let box = try Sandbox()
        try box.write(.codex, codexFixture + "[model_providers.downshift]\nname = \"x\"\n")
        #expect(throws: AppsError.self) { try box.manager.enable(.codex) }
        try box.write(.codex, "model_provider = \"azure\"\n" + codexFixture)
        #expect(throws: AppsError.self) { try box.manager.enable(.codex) }
        guard case .enabled = try box.manager.enable(.codex, codexDefaultProvider: false) else { Issue.record("expected enable"); return }
        #expect(try box.read(.codex).hasPrefix("model_provider = \"azure\"\n"))
    }

    @Test func differentPortWhileEnabledIsRefused() throws {
        let box = try Sandbox()
        _ = try box.manager.enable(.claude)
        #expect(throws: AppsError.self) { try box.manager.enable(.claude, port: 50000) }
    }

    @Test func codexWithoutFinalNewlineRoundTrips() throws {
        let box = try Sandbox()
        let original = "model = \"o3\"\n\n[tui]\nnotifications = true"
        try box.write(.codex, original)
        _ = try box.manager.enable(.codex)
        try box.write(.codex, try box.read(.codex) + "# touched\n")
        _ = try box.manager.disable(.codex)
        let result = try box.read(.codex)
        #expect(result == original + "\n# touched", "\(result.debugDescription)")
    }

    @Test func codexCRLFRoundTrips() throws {
        let box = try Sandbox()
        let original = codexFixture.replacingOccurrences(of: "\n", with: "\r\n")
        try box.write(.codex, original)
        _ = try box.manager.enable(.codex)
        _ = try box.manager.disable(.codex)
        #expect(try box.read(.codex) == original)
    }

    @Test func stateAndBackupsArePrivate() throws {
        let box = try Sandbox()
        try box.write(.claude, claudeFixture)
        guard case .enabled(let backup?) = try box.manager.enable(.claude) else { return }
        func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        #expect(try mode(box.manager.locations.stateFile) == 0o600)
        #expect(try mode(backup) == 0o600)
        #expect(try mode(box.manager.locations.backupsDirectory) == 0o700)
    }

    @Test func statusReportsEnabledApps() throws {
        let box = try Sandbox()
        _ = try box.manager.enable(.codex)
        let status = try box.manager.status()
        #expect(status.first { $0.app == .claude }?.enabled == false)
        let codex = try #require(status.first { $0.app == .codex })
        #expect(codex.enabled && codex.baseURL == "http://127.0.0.1:47821/codex" && codex.defaultProvider == true)
    }
}

@Suite struct PrettyJSONTests {
    @Test func matchesJSONStringify() throws {
        let value = try JSONValue.parse(#"{"a":[1,{"b":null}],"e":{},"f":[],"s":"x\"y"}"#)
        // JSON.stringify(v, null, 2)
        let expected = """
            {
              "a": [
                1,
                {
                  "b": null
                }
              ],
              "e": {},
              "f": [],
              "s": "x\\"y"
            }
            """
        #expect(String(decoding: value.serialized(indent: 2), as: UTF8.self) == expected)
    }
}
