import Foundation
import Testing
@testable import DownshiftAgents

/// Stands in for `/bin/launchctl`: records calls and tracks whether the job is loaded.
final class FakeLaunchctl: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var loaded = false
    /// How many bootstraps fail (as launchd does while a booted-out job is still going away).
    var failingBootstraps = 0

    var calls: [[String]] { lock.withLock { _calls } }
    var verbs: [String] { calls.map { $0[0] } }

    var run: LaunchAgent.Launchctl {
        { [self] arguments in
            lock.withLock {
                _calls.append(arguments)
                switch arguments[0] {
                case "print": return loaded ? (0, "gui/501/dev.downshift.serve = {\n\tstate = running\n\tpid = 4242\n}\n") : (113, "Could not find service")
                case "bootout":
                    defer { loaded = false }
                    return loaded ? (0, "") : (3, "No such process")
                case "bootstrap":
                    if failingBootstraps > 0 { failingBootstraps -= 1; return (5, "Bootstrap failed: 5: Input/output error") }
                    loaded = true
                    return (0, "")
                default: return (0, "")
                }
            }
        }
    }
}

struct LaunchAgentTests {
    let home: URL
    let launchctl = FakeLaunchctl()

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dshift-launchagent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var agent: LaunchAgent { LaunchAgent(home: home, uid: 501, launchctl: launchctl.run, retryDelay: {}) }

    @Test func plistContents() throws {
        let data = try LaunchAgent.plist(executable: "/opt/homebrew/bin/dshift", port: 47821,
                                         log: URL(fileURLWithPath: "/Users/me/Library/Logs/downshift/serve.log"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "dev.downshift.serve")
        #expect(plist["ProgramArguments"] as? [String] == ["/opt/homebrew/bin/dshift", "serve", "run", "--port", "47821"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["StandardErrorPath"] as? String == "/Users/me/Library/Logs/downshift/serve.log")
        // Deterministic, so an unchanged install can be detected by comparing bytes.
        #expect(data == (try LaunchAgent.plist(executable: "/opt/homebrew/bin/dshift", port: 47821,
                                               log: URL(fileURLWithPath: "/Users/me/Library/Logs/downshift/serve.log"))))
    }

    @Test func executablePathKeepsSymlinksAndResolvesRelativeAndPATH() throws {
        #expect(LaunchAgent.executablePath(invokedAs: "/opt/homebrew/bin/dshift") == "/opt/homebrew/bin/dshift")
        #expect(LaunchAgent.executablePath(invokedAs: ".build/debug/dshift", currentDirectory: "/src/downshift")
                == "/src/downshift/.build/debug/dshift")
        #expect(LaunchAgent.executablePath(invokedAs: "../bin/./dshift", currentDirectory: "/usr/local/share") == "/usr/local/bin/dshift")

        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("dshift")
        FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        #expect(LaunchAgent.executablePath(invokedAs: "dshift", searchPath: "relative:/nonexistent:\(bin.path)") == tool.path)
        #expect(LaunchAgent.executablePath(invokedAs: "dshift", searchPath: "/nonexistent") == nil)
    }

    @Test func restartKickstartsOnlyALoadedJob() throws {
        #expect(!agent.restart())
        #expect(!launchctl.verbs.contains("kickstart"))
        try agent.install(executable: "/opt/homebrew/bin/dshift", port: 47821)
        #expect(agent.restart())
        #expect(launchctl.calls.last == ["kickstart", "-k", "gui/501/dev.downshift.serve"])
    }

    @Test func installThenUninstall() throws {
        #expect(try agent.install(executable: "/opt/homebrew/bin/dshift", port: 47821) == .installed)
        #expect(FileManager.default.fileExists(atPath: agent.plistURL.path))
        #expect(launchctl.calls.contains(["bootstrap", "gui/501", agent.plistURL.path]))
        #expect(launchctl.calls.contains(["enable", "gui/501/dev.downshift.serve"]))
        let logs = try FileManager.default.attributesOfItem(atPath: agent.logURL.deletingLastPathComponent().path)
        #expect(logs[.posixPermissions] as? Int == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: agent.logURL.path))[.posixPermissions] as? Int == 0o600)

        let status = agent.status()
        #expect(status == .init(installed: true, loaded: true, pid: 4242, port: 47821, executable: "/opt/homebrew/bin/dshift"))

        #expect(try agent.uninstall())
        #expect(!FileManager.default.fileExists(atPath: agent.plistURL.path))
        #expect(launchctl.verbs.last == "bootout")
        #expect(agent.status() == .init(installed: false, loaded: false))
        #expect(try agent.uninstall() == false)
    }

    @Test func reinstallSameIsNoOpAndDifferentPortReloads() throws {
        _ = try agent.install(executable: "/opt/homebrew/bin/dshift", port: 47821)
        let before = launchctl.calls.count
        #expect(try agent.install(executable: "/opt/homebrew/bin/dshift", port: 47821) == .alreadyInstalled)
        #expect(launchctl.verbs[before...].allSatisfy { $0 == "print" })

        #expect(try agent.install(executable: "/opt/homebrew/bin/dshift", port: 50000) == .replaced)
        #expect(Array(launchctl.verbs[before...].filter { $0 != "print" }) == ["bootout", "enable", "bootstrap"])
        #expect(agent.status().port == 50000)
    }

    @Test func plistPresentButUnloadedGetsLoaded() throws {
        _ = try agent.install(executable: "/opt/homebrew/bin/dshift", port: 47821)
        _ = launchctl.run(["bootout", "gui/501/dev.downshift.serve"])
        #expect(agent.status().loaded == false)
        #expect(try agent.install(executable: "/opt/homebrew/bin/dshift", port: 47821) == .replaced)
        #expect(agent.status().loaded)
    }

    @Test func bootstrapIsRetriedThenReportsFailure() throws {
        launchctl.failingBootstraps = 2
        #expect(try agent.install(executable: "/opt/homebrew/bin/dshift", port: 47821) == .installed)

        try agent.uninstall()
        launchctl.failingBootstraps = 100
        #expect(throws: AppsError.self) { try agent.install(executable: "/opt/homebrew/bin/dshift", port: 47821) }
    }

    @Test func developmentBuildsAreStagedOutOfTheSourceTree() throws {
        let build = home.appendingPathComponent("src/downshift/.build/debug")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let binary = build.appendingPathComponent("dshift")
        FileManager.default.createFile(atPath: binary.path, contents: Data("v1".utf8), attributes: [.posixPermissions: 0o755])
        let staged = agent.stagingDirectory.appendingPathComponent("dshift")

        #expect(try agent.install(executable: binary.path, port: 47821) == .installed)
        #expect(agent.status().executable == staged.path)
        #expect(try Data(contentsOf: staged) == Data("v1".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? Int == 0o755)
        #expect(try FileManager.default.attributesOfItem(atPath: agent.stagingDirectory.path)[.posixPermissions] as? Int == 0o700)

        // Same bytes: nothing to do. A rebuild: same plist, but the agent must reload.
        #expect(try agent.install(executable: binary.path, port: 47821) == .alreadyInstalled)
        let inode = try FileManager.default.attributesOfItem(atPath: staged.path)[.systemFileNumber] as? Int
        try Data("v2".utf8).write(to: binary)
        let before = launchctl.calls.count
        #expect(try agent.install(executable: binary.path, port: 47821) == .replaced)
        #expect(launchctl.verbs[before...].contains("bootstrap"))
        #expect(try Data(contentsOf: staged) == Data("v2".utf8))
        // Replaced by rename, not rewritten in place.
        #expect(try FileManager.default.attributesOfItem(atPath: staged.path)[.systemFileNumber] as? Int != inode)

        try agent.uninstall()
        #expect(!FileManager.default.fileExists(atPath: agent.stagingDirectory.path))
    }

    @Test func installedBuildsRunInPlace() throws {
        #expect(!LaunchAgent.isDevelopmentBuild("/opt/homebrew/bin/dshift"))
        #expect(!LaunchAgent.isDevelopmentBuild("/Users/me/.mint/bin/dshift"))
        #expect(LaunchAgent.isDevelopmentBuild("/Users/me/src/dshift/.build/arm64-apple-macosx/release/dshift"))
        _ = try agent.install(executable: "/opt/homebrew/bin/dshift", port: 47821)
        #expect(!FileManager.default.fileExists(atPath: agent.stagingDirectory.path))
    }

    @Test func aMissingDevelopmentBuildIsAClearError() {
        #expect(throws: AppsError.self) { try agent.install(executable: "/nonexistent/.build/debug/dshift", port: 47821) }
        #expect(!FileManager.default.fileExists(atPath: agent.plistURL.path))
    }

    @Test func pidParsing() {
        #expect(LaunchAgent.pid(fromPrint: "x = {\n\tpid = 99\n\tstate = running\n}") == 99)
        #expect(LaunchAgent.pid(fromPrint: "x = {\n\tstate = not running\n}") == nil)
    }
}
