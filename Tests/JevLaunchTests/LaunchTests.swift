import Foundation
import Logging
import Testing
@testable import JevAgents
@testable import JevCore
@testable import JevLaunch
@testable import JevProxy

func temporaryDirectory(_ name: String = "jev-launch") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// Spawns and signals real processes, and changes this process's SIGINT disposition.
@Suite(.serialized) struct ChildProcessTests {
    let environment = ["PATH": "/usr/bin:/bin"]

    @Test func exitCodePassesThrough() async throws {
        let child = try ChildProcess.spawn("/bin/sh", arguments: ["-c", "exit 3"], environment: environment)
        #expect(await child.wait() == .exited(3))
    }

    @Test func killedChildMapsTo128PlusSignal() async throws {
        let child = try ChildProcess.spawn("/bin/sh", arguments: ["-c", "kill -TERM $$"], environment: environment)
        let ended = await child.wait()
        #expect(ended == .signaled(SIGTERM))
        #expect(ended.exitCode == 143)
    }

    @Test func childGetsDefaultSigintWhileParentIgnoresIt() async throws {
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }
        // A non-interactive shell can't undo an inherited SIG_IGN, so this only dies if the
        // spawn reset SIGINT to its default.
        let child = try ChildProcess.spawn("/bin/sh", arguments: ["-c", "kill -INT $$; exit 0"], environment: environment)
        #expect(await child.wait() == .signaled(SIGINT))
    }

    @Test func missingExecutableThrows() {
        #expect(throws: SpawnError.self) {
            try ChildProcess.spawn("/nonexistent/claude", arguments: [], environment: environment)
        }
    }

    @Test func launcherRunsChildAfterPortThenCleansUp() async throws {
        let previous = (signal(SIGINT, SIG_DFL), signal(SIGQUIT, SIG_DFL))
        defer { signal(SIGINT, previous.0); signal(SIGQUIT, previous.1) }
        let order = Locked<[String]>([])
        let child = Launcher.Child(
            executable: "/bin/sh",
            arguments: { port in ["-c", "test \(port) -gt 0 && exit 5"] },
            environment: { _ in ["PATH": "/usr/bin:/bin"] })
        let configuration = ProxyServer.Configuration(port: 0, codexUpstream: "", shutdownGrace: .seconds(2))
        var logger = Logger(label: "test")
        logger.logLevel = .critical
        let ended = try await Launcher.run(configuration, child: child, logger: logger) {
            order.withLock { $0.append("cleanup") }
        }
        #expect(ended == .exited(5))
        #expect(order.value == ["cleanup"])
    }
}

@Suite struct PortGateTests {
    @Test func waitersGetThePortOnceOpened() async throws {
        let gate = PortGate()
        async let first = gate.wait()
        async let second = gate.wait()
        try await Task.sleep(for: .milliseconds(20))
        gate.open(4242)
        #expect(try await first == 4242)
        #expect(try await second == 4242)
        #expect(try await gate.wait() == 4242)
    }

    @Test func cancelledWaitThrows() async {
        let gate = PortGate()
        let task = Task { try await gate.wait() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct ForwardedArgumentsTests {
    @Test func extractsLastValueInBothForms() {
        let (value, rest) = ForwardedArguments.extract(["--model"], from: ["--model", "opus", "-p", "--model=sonnet", "hi"])
        #expect(value == "sonnet")
        #expect(rest == ["-p", "hi"])
    }

    @Test func stopsAtDoubleDash() {
        let (value, rest) = ForwardedArguments.extract(["--model"], from: ["-p", "--", "--model", "opus"])
        #expect(value == nil)
        #expect(rest == ["-p", "--", "--model", "opus"])
        #expect(!ForwardedArguments.contains(["--model"], in: ["--", "--model"]))
        #expect(ForwardedArguments.contains(["--settings"], in: ["--settings=x.json"]))
    }
}

@Suite struct ClaudeLaunchTests {
    @Test func baselinePrefersFlagThenEnvironmentThenSettings() throws {
        let root = try temporaryDirectory()
        let user = root.appendingPathComponent("user/settings.json")
        let files = ClaudeLaunch.settingsFiles(currentDirectory: root, userSettings: user)
        try write(#"{"model":"haiku"}"#, to: user)
        #expect(ClaudeLaunch.baselineModel(arguments: [], environment: [:], settingsFiles: files) == "haiku")
        try write(#"{"model":"sonnet"}"#, to: root.appendingPathComponent(".claude/settings.json"))
        #expect(ClaudeLaunch.baselineModel(arguments: [], environment: [:], settingsFiles: files) == "sonnet")
        try write(#"{"model":"jev-router"}"#, to: root.appendingPathComponent(".claude/settings.local.json"))
        #expect(ClaudeLaunch.baselineModel(arguments: [], environment: [:], settingsFiles: files) == "sonnet")
        #expect(ClaudeLaunch.baselineModel(arguments: [], environment: ["ANTHROPIC_MODEL": "opus"], settingsFiles: files) == "opus")
        #expect(ClaudeLaunch.baselineModel(arguments: [], environment: ["ANTHROPIC_MODEL": "jev-router"], settingsFiles: files) == "sonnet")
        #expect(ClaudeLaunch.baselineModel(arguments: ["--model=fable"], environment: ["ANTHROPIC_MODEL": "opus"], settingsFiles: files) == "fable")
    }

    @Test func ownStatusLineIsDetected() throws {
        let root = try temporaryDirectory()
        let user = root.appendingPathComponent("user/settings.json")
        let files = ClaudeLaunch.settingsFiles(currentDirectory: root, userSettings: user)
        #expect(!ClaudeLaunch.hasOwnStatusLine(settingsFiles: files))
        try write(#"{"statusLine":{"type":"command","command":"x"}}"#, to: user)
        #expect(ClaudeLaunch.hasOwnStatusLine(settingsFiles: files))
    }

    @Test func argumentsAddJevsFirstAndDropModelWhenRouting() {
        let root = URL(fileURLWithPath: "/tmp/skill-root")
        let settings = URL(fileURLWithPath: "/tmp/settings.json")
        let forwarded = ["--model", "opus", "-p", "hi", "--", "--model"]
        #expect(ClaudeLaunch.arguments(forwarded, route: true, skillRoot: root, settingsFile: settings)
            == ["--add-dir", "/tmp/skill-root", "--settings", "/tmp/settings.json", "-p", "hi", "--", "--model"])
        #expect(ClaudeLaunch.arguments(forwarded, route: false, skillRoot: nil, settingsFile: nil) == forwarded)
        #expect(ClaudeLaunch.arguments(["mcp", "list"], route: true, skillRoot: root, settingsFile: settings) == ["mcp", "list"])
    }

    @Test func environmentPointsAtProxy() {
        let routed = ClaudeLaunch.environment(["ANTHROPIC_MODEL": "opus", "KEEP": "1"], baseURL: "http://127.0.0.1:9", route: true)
        #expect(routed["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:9")
        #expect(routed["ANTHROPIC_MODEL"] == "jev-router")
        #expect(routed["KEEP"] == "1")
        #expect(routed["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] == "1")
        let plain = ClaudeLaunch.environment(["ANTHROPIC_MODEL": "opus"], baseURL: "http://127.0.0.1:9", route: false)
        #expect(plain["ANTHROPIC_MODEL"] == "opus")
    }

    @Test func statusLineSettingsRunJev() throws {
        let data = ClaudeLaunch.statusLineSettings(command: "/opt/jev")
        let value = try JSONValue.parse(data)
        #expect(value["statusLine"]?["command"]?.stringValue == "/opt/jev statusline")
        #expect(value["statusLine"]?["type"]?.stringValue == "command")
    }
}

@Suite struct CodexLaunchTests {
    @Test func baselineFromFlagProfileOrConfig() throws {
        let home = try temporaryDirectory()
        try write("""
            model = "gpt-5.5" # default
            [profiles.legacy]
            model = "o3"
            [other]
            model = "nope"
            """, to: home.appendingPathComponent("config.toml"))
        try write(#"model = "gpt-5.5-mini""#, to: home.appendingPathComponent("fast.config.toml"))
        #expect(CodexLaunch.baselineModel(arguments: [], codexHome: home) == "gpt-5.5")
        #expect(CodexLaunch.baselineModel(arguments: ["-p", "fast"], codexHome: home) == "gpt-5.5-mini")
        #expect(CodexLaunch.baselineModel(arguments: ["--profile=legacy"], codexHome: home) == "o3")
        #expect(CodexLaunch.baselineModel(arguments: ["-p", "missing"], codexHome: home) == "gpt-5.5")
        #expect(CodexLaunch.baselineModel(arguments: ["-p", "fast", "-m", "o4"], codexHome: home) == "o4")
    }

    @Test func tableStringReadsOnlyThatTable() {
        let data = Data("[a]\nkey = \"x\"\n[a.b]\nkey = 'y' # c\n[c]\nkey = \"z\"\n".utf8)
        #expect(CodexConfigEdit.tableString(data, table: ["a", "b"], key: "key") == "y")
        #expect(CodexConfigEdit.tableString(data, table: ["a"], key: "key") == "x")
        #expect(CodexConfigEdit.tableString(data, table: ["d"], key: "key") == nil)
    }

    @Test func argumentsConfigureProviderBeforeUserArguments() {
        let routed = CodexLaunch.arguments(["-m", "o3", "exec", "hi"], baseURL: "http://127.0.0.1:9/codex", route: true)
        #expect(Array(routed.prefix(2)) == ["--model", "jev-router"])
        #expect(Array(routed.suffix(2)) == ["exec", "hi"])
        #expect(routed.contains("model_providers.jev.base_url=\"http://127.0.0.1:9/codex\""))
        #expect(routed.contains("model_providers.jev.supports_websockets=false"))
        #expect(!routed.contains("o3"))
        let plain = CodexLaunch.arguments(["-m", "o3"], baseURL: "u", route: false)
        #expect(plain.first == "--config")
        #expect(Array(plain.suffix(2)) == ["-m", "o3"])
    }

    @Test func statusIDIsPerProcess() {
        #expect(CodexLaunch.statusID(pid: 42) == "codex-42")
    }
}

@Suite struct SkillTests {
    @Test func rendersCommandIntoBothAgents() {
        let claude = Skill.explain.render(.claude, "/opt/jev")
        #expect(claude.contains("allowed-tools: Bash(/opt/jev explain *)"))
        #expect(claude.contains(#"!`/opt/jev explain "${CLAUDE_SESSION_ID}"`"#))
        #expect(claude.contains("<jev-explain>"))
        let codex = Skill.explain.render(.codex, "jev")
        #expect(codex.contains("Run `jev explain` once"))
        #expect(SkillInstaller.command(executable: "/Users/a b/jev") == #""/Users/a b/jev""#)
        #expect(SkillInstaller.command(executable: nil) == "jev")
    }

    @Test func installRefreshesOwnFilesAndKeepsForeignOnes() throws {
        let directory = try temporaryDirectory()
        let file = SkillInstaller.file(.explain, in: directory)
        #expect(SkillInstaller.state(.explain, agent: .claude, command: "jev", in: directory) == .missing)
        #expect(try SkillInstaller.install(.explain, agent: .claude, command: "jev", in: directory) == .written)
        #expect(try SkillInstaller.install(.explain, agent: .claude, command: "jev", in: directory) == .unchanged)
        #expect(SkillInstaller.state(.explain, agent: .claude, command: "/opt/jev", in: directory) == .outdated)
        #expect(try SkillInstaller.install(.explain, agent: .claude, command: "/opt/jev", in: directory) == .written)
        try write("my own skill", to: file)
        #expect(SkillInstaller.state(.explain, agent: .claude, command: "jev", in: directory) == .foreign)
        #expect(try SkillInstaller.install(.explain, agent: .claude, command: "jev", in: directory) == .skippedForeign)
        #expect(try String(contentsOf: file, encoding: .utf8) == "my own skill")
        #expect(try SkillInstaller.install(.explain, agent: .claude, command: "jev", in: directory, force: true) == .written)
    }

    @Test func userDirectoriesFollowHomeAndClaudeConfigDir() {
        let environment = ["HOME": "/h", "CLAUDE_CONFIG_DIR": "/c"]
        #expect(SkillInstaller.userSkillsDirectory(.claude, environment: environment).path == "/c/skills")
        #expect(SkillInstaller.userSkillsDirectory(.codex, environment: environment).path == "/h/.agents/skills")
        #expect(SkillInstaller.userSkillsDirectory(.claude, environment: ["HOME": "/h"]).path == "/h/.claude/skills")
    }
}

@Suite struct StatusTests {
    @Test func latestSessionAndStatusLine() throws {
        let store = StatusStore(directory: try temporaryDirectory("jev-status"))
        store.write(["tier": "fast", "model": "claude-haiku"], session: "older")
        try Task.checkCancellation()
        usleep(20_000)
        store.write(["tier": "strong", "model": "claude-opus"], session: "newer")
        #expect(store.latestSession() == "newer")
        let line = StatusLine.render(input: ["session_id": "newer", "workspace": ["current_dir": "/x/project"]],
                                     status: store.read(session: "newer"))
        #expect(line.contains("project"))
        #expect(line.contains("strong") || line.contains("opus"))
    }

    @Test func executablePathIsAbsoluteAndKeepsSymlinks() throws {
        let folder = try temporaryDirectory()
        let jev = folder.appendingPathComponent("jev")
        try write("#!/bin/sh\n", to: jev)
        chmod(jev.path, 0o755)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.appendingPathComponent("jev").path, withDestinationPath: jev.path)
        #expect(JevExecutable.path(invokedAs: link.appendingPathComponent("jev").path) == link.appendingPathComponent("jev").path)
        #expect(JevExecutable.path(invokedAs: "jev", environment: ["PATH": folder.path]) == jev.path)
    }
}
