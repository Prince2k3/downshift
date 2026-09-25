import Foundation
import Logging
import Testing
@testable import DownshiftAgents
@testable import DownshiftCore
@testable import DownshiftLaunch
@testable import DownshiftProxy

func temporaryDirectory(_ name: String = "dshift-launch") throws -> URL {
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
        try write(#"{"model":"downshift"}"#, to: root.appendingPathComponent(".claude/settings.local.json"))
        #expect(ClaudeLaunch.baselineModel(arguments: [], environment: [:], settingsFiles: files) == "sonnet")
        #expect(ClaudeLaunch.baselineModel(arguments: [], environment: ["ANTHROPIC_MODEL": "opus"], settingsFiles: files) == "opus")
        #expect(ClaudeLaunch.baselineModel(arguments: [], environment: ["ANTHROPIC_MODEL": "downshift"], settingsFiles: files) == "sonnet")
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

    @Test func argumentsAddDshiftsFirstAndDropModelWhenRouting() {
        let settings = URL(fileURLWithPath: "/tmp/settings.json")
        let forwarded = ["--model", "opus", "-p", "hi", "--", "--model"]
        #expect(ClaudeLaunch.arguments(forwarded, route: true, settingsFile: settings)
            == ["--settings", "/tmp/settings.json", "-p", "hi", "--", "--model"])
        #expect(ClaudeLaunch.arguments(forwarded, route: false, settingsFile: nil) == forwarded)
        #expect(ClaudeLaunch.arguments(["mcp", "list"], route: true, settingsFile: settings) == ["mcp", "list"])
    }

    @Test func statusLineCommandQuotesPathsWithSpaces() {
        #expect(ClaudeLaunch.command(executable: "/Users/a b/dshift") == #""/Users/a b/dshift""#)
        #expect(ClaudeLaunch.command(executable: "/opt/dshift") == "/opt/dshift")
    }

    @Test func environmentPointsAtProxy() {
        let routed = ClaudeLaunch.environment(["ANTHROPIC_MODEL": "opus", "KEEP": "1"], baseURL: "http://127.0.0.1:9", route: true)
        #expect(routed["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:9")
        #expect(routed["ANTHROPIC_MODEL"] == "downshift")
        #expect(routed["KEEP"] == "1")
        #expect(routed["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] == "1")
        let plain = ClaudeLaunch.environment(["ANTHROPIC_MODEL": "opus"], baseURL: "http://127.0.0.1:9", route: false)
        #expect(plain["ANTHROPIC_MODEL"] == "opus")
    }

    @Test func statusLineSettingsRunJev() throws {
        let data = ClaudeLaunch.statusLineSettings(command: "/opt/dshift")
        let value = try JSONValue.parse(data)
        #expect(value["statusLine"]?["command"]?.stringValue == "/opt/dshift statusline")
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
        #expect(Array(routed.prefix(2)) == ["--model", "downshift"])
        #expect(Array(routed.suffix(2)) == ["exec", "hi"])
        #expect(routed.contains("model_providers.downshift.base_url=\"http://127.0.0.1:9/codex\""))
        #expect(routed.contains("model_providers.downshift.supports_websockets=false"))
        #expect(!routed.contains("o3"))
        #expect(routed.contains("model_provider=\"downshift\""))
        #expect(routed.contains("model_providers.downshift.requires_openai_auth=true"))
        let long = CodexLaunch.arguments(["--model", "gpt-5.6-sol"], baseURL: "u", route: true)
        #expect(long.filter { $0 == "--model" }.count == 1)
        #expect(!long.contains("gpt-5.6-sol"))
        let plain = CodexLaunch.arguments(["-m", "o3"], baseURL: "u", route: false)
        #expect(plain.first == "--config")
        #expect(Array(plain.suffix(2)) == ["-m", "o3"])
    }
}

@Suite struct StatusTests {
    @Test func statusLineShowsTheSessionsDecision() throws {
        let store = StatusStore(directory: try temporaryDirectory("jev-status"))
        store.write(["tier": "fast", "model": "claude-haiku"], session: "older")
        store.write(["tier": "strong", "model": "claude-opus"], session: "newer")
        let line = StatusLine.render(input: ["session_id": "newer", "workspace": ["current_dir": "/x/project"]],
                                     status: store.read(session: "newer"))
        #expect(line.contains("project"))
        #expect(line.contains("strong") || line.contains("opus"))
    }

    @Test func executablePathIsAbsoluteAndKeepsSymlinks() throws {
        let folder = try temporaryDirectory()
        let dshift = folder.appendingPathComponent("dshift")
        try write("#!/bin/sh\n", to: dshift)
        chmod(dshift.path, 0o755)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.appendingPathComponent("dshift").path, withDestinationPath: dshift.path)
        #expect(DownshiftExecutable.path(invokedAs: link.appendingPathComponent("dshift").path) == link.appendingPathComponent("dshift").path)
        #expect(DownshiftExecutable.path(invokedAs: "dshift", environment: ["PATH": folder.path]) == dshift.path)
    }
}
