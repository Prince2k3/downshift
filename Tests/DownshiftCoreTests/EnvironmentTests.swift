import Foundation
import Testing
@testable import DownshiftCore

struct EnvFileTests {
    func parsed(_ text: String) -> [String: String] {
        Dictionary(EnvFile.parse(text).map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
    }

    @Test func basicsCommentsAndExport() {
        let env = parsed("""
            # a comment
            DSHIFT_API_KEY=abc123

            export DSHIFT_HOST = cloudflare
              INDENTED=yes
            INLINE=value # trailing comment
            HASH=a#b
            EMPTY=
            not a line
            =novalue
            """)
        #expect(env == ["DSHIFT_API_KEY": "abc123", "DSHIFT_HOST": "cloudflare", "INDENTED": "yes",
                        "INLINE": "value", "HASH": "a#b", "EMPTY": ""])
    }

    @Test func quotes() {
        let env = parsed("""
            DOUBLE="line one\\nline two"
            SINGLE='kept \\n literally # not a comment'
            BACKTICK=`it's "fine"`
            MULTI="first
            second"
            AFTER=1
            """)
        #expect(env["DOUBLE"] == "line one\nline two")
        #expect(env["SINGLE"] == "kept \\n literally # not a comment")
        #expect(env["BACKTICK"] == #"it's "fine""#)
        #expect(env["MULTI"] == "first\nsecond")
        #expect(env["AFTER"] == "1")
    }

    @Test func crlfAndDuplicates() {
        #expect(parsed("A=1\r\nA=2\r\nB=x\r\n") == ["A": "2", "B": "x"])
    }
}

struct DownshiftEnvironmentTests {
    @Test func precedenceIsProcessThenDotEnvThenHomeFiles() throws {
        let cwd = try temporaryDirectory("cwd")
        let home = try temporaryDirectory("home")
        try "A=dotenv\nB=dotenv\n".write(to: cwd.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "B=router\nC=router\n".write(to: home.appendingPathComponent(".jev-router.env"), atomically: true, encoding: .utf8)
        try "C=legacy\nD=legacy\n".write(to: home.appendingPathComponent(".jev-claude.env"), atomically: true, encoding: .utf8)

        let env = DownshiftEnvironment.load(process: ["A": "process"], currentDirectory: cwd, home: home, credentials: nil)
        #expect(env["A"] == "process")
        #expect(env["B"] == "dotenv")
        #expect(env["C"] == "router")
        #expect(env["D"] == "legacy")
        #expect(env.loadedFiles.map(\.lastPathComponent) == [".env", ".jev-router.env", ".jev-claude.env"])
    }

    @Test func legacyJevVariablesAreReadAsDshift() throws {
        let cwd = try temporaryDirectory("cwd")
        let home = try temporaryDirectory("home")
        try "JEV_MODEL=file\nJEV_DUMP=file\nDSHIFT_DUMP=new-file\n"
            .write(to: home.appendingPathComponent(".jev-router.env"), atomically: true, encoding: .utf8)
        let env = DownshiftEnvironment.load(
            process: ["JEV_HOST": "vercel", "JEV_DEBUG": "1", "DSHIFT_DEBUG": "", "CLOUDFLARE_API_TOKEN_JEV": "t"],
            currentDirectory: cwd, home: home, stored: .success(["JEV_MODEL": "stored"]))
        #expect(env["DSHIFT_HOST"] == "vercel")
        #expect(env["DSHIFT_DEBUG"] == "")          // the new name wins within one place
        #expect(env["DSHIFT_MODEL"] == "stored")    // an earlier place wins over a later one
        #expect(env["DSHIFT_DUMP"] == "new-file")
        #expect(env["CLOUDFLARE_API_TOKEN_JEV"] == "t")
        #expect(env["JEV_HOST"] == nil)
        #expect(env.storedKeys == ["DSHIFT_MODEL"])
    }

    @Test func keychainValuesSitBetweenProcessAndFiles() throws {
        let cwd = try temporaryDirectory("cwd")
        let home = try temporaryDirectory("home")
        try "A=dotenv\nB=dotenv\n".write(to: cwd.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let env = DownshiftEnvironment.load(process: ["P": "process"], currentDirectory: cwd, home: home,
                                      stored: .success(["P": "stored", "A": "stored"]))
        #expect(env["P"] == "process")
        #expect(env["A"] == "stored")
        #expect(env["B"] == "dotenv")
        #expect(env.storedKeys == ["A"])
        #expect(env.credentialProblem == nil)
    }

    @Test func unreadableKeychainStillLoads() throws {
        struct Locked: Error, CustomStringConvertible { var description: String { "locked" } }
        let env = DownshiftEnvironment.load(process: ["X": "1"], currentDirectory: try temporaryDirectory("cwd"),
                                      home: try temporaryDirectory("home"), stored: .failure(Locked()))
        #expect(env.values == ["X": "1"])
        #expect(env.credentialProblem == "locked")
    }

    @Test func missingFilesAreSkipped() throws {
        let env = DownshiftEnvironment.load(process: ["X": "1"], currentDirectory: try temporaryDirectory("cwd"),
                                      home: try temporaryDirectory("home"), credentials: nil)
        #expect(env.values == ["X": "1"])
        #expect(env.loadedFiles.isEmpty)
    }

    @Test func settingsFromEnvironment() {
        let settings = DownshiftSettings(environment: .init(values: [
            "DSHIFT_HOST": "vercel", "DSHIFT_DEBUG": "1", "DSHIFT_NO_STATUSLINE": "1", "DSHIFT_DUMP": "",
            "DSHIFT_CODEX_FAST_MODEL": "gpt-x-mini",
        ]))
        #expect(settings.host == "vercel")
        #expect(settings.debug)
        #expect(!settings.statusLine)
        #expect(settings.dumpDirectory == nil)
        #expect(settings.jevModel == nil)
        #expect(settings.codexModel(.fast) == "gpt-x-mini")
        #expect(settings.codexModel(.strong) == "gpt-5.6-sol")

        let defaults = DownshiftSettings(environment: .init(values: ["DSHIFT_DEBUG": ""]))
        #expect(!defaults.debug)
        #expect(defaults.statusLine)
        #expect(defaults.host == nil)
    }
}

struct StatusStoreTests {
    let store: StatusStore

    init() throws { store = StatusStore(directory: try temporaryDirectory("status").appendingPathComponent("jev")) }

    @Test func writesPrivatelyAndReadsBack() throws {
        store.write(["tier": "strong", "at": 1], session: "abc-123")
        #expect(store.read(session: "abc-123") == ["tier": "strong", "at": 1])
        let attributes = { try FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? Int }
        #expect(try attributes(store.directory.path) == 0o700)
        #expect(try attributes(store.directory.appendingPathComponent("abc-123.json").path) == 0o600)
    }

    @Test func sessionIdsCannotEscapeTheDirectory() {
        #expect(store.file(for: "../../etc/passwd")?.lastPathComponent == "etcpasswd.json")
        #expect(store.file(for: "../") == nil)
        store.write(["x": 1], session: "/..")
        #expect(store.read(session: "/..") == nil)
    }

    @Test func manualStatusReplacesTheDecision() {
        store.write(["tier": "fast"], session: "m")
        store.write(["manual": true], session: "m")
        #expect(store.read(session: "m") == ["manual": true])
    }

    @Test func prunesOnlyStaleJSONFiles() throws {
        store.write(["x": 1], session: "old")
        store.write(["x": 1], session: "new")
        let other = store.directory.appendingPathComponent("keep.txt")
        try Data().write(to: other)
        let old = store.directory.appendingPathComponent("old.json")
        let longAgo = Date().addingTimeInterval(-StatusStore.staleAfter - 60)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: other.path)

        #expect(store.pruneStale() == 1)
        #expect(store.read(session: "old") == nil)
        #expect(store.read(session: "new") != nil)
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func aMissingDirectoryIsNothingToPrune() {
        #expect(StatusStore(directory: URL(fileURLWithPath: "/nonexistent/jev")).pruneStale() == 0)
    }
}

struct LogTests {
    @Test func fileLogIsPrivateAndDebugIsGated() throws {
        let file = try temporaryDirectory("log").appendingPathComponent("logs/jev.log")
        let log = DownshiftLog(destination: .file(file))
        log.log("routing failed, keeping strong")
        log.debug("hidden")
        DownshiftLog(destination: .file(file), debugEnabled: true).debug("shown")

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("[dshift] routing failed, keeping strong\n"))
        #expect(!text.contains("hidden"))
        #expect(text.contains("[dshift] shown\n"))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
    }
}

/// Writes to the real login keychain under a throwaway service, then deletes it. Off unless
/// DSHIFT_KEYCHAIN_TEST=1, since it touches the user's keychain.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DSHIFT_KEYCHAIN_TEST"] == "1"))
struct CredentialStoreTests {
    @Test func roundTripsAndDeletes() throws {
        let store = CredentialStore(service: "dev.downshift.test-\(UUID().uuidString)")
        defer { try? store.delete() }
        #expect(try store.read() == [:])
        try store.write(["A": "1", "B": "2"])
        #expect(try store.read() == ["A": "1", "B": "2"])
        try store.write(["A": "3"])
        #expect(try store.read() == ["A": "3"])
        try store.write([:])
        #expect(try store.read() == [:])
    }
}
