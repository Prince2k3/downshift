import Foundation
import Testing
@testable import DownshiftCore

func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dshift-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Port of `test/settings.test.mjs`, plus formatting preservation.
struct ClaudeSettingsTests {
    func file(_ text: String) throws -> URL {
        let url = try temporaryDirectory("settings").appendingPathComponent("settings.json")
        try Data(text.utf8).write(to: url)
        return url
    }

    func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func readsTheSavedModelIgnoringALeftoverSentinel() throws {
        #expect(ClaudeSettings.savedModel(in: try file(#"{"model": "opus"}"#)) == "opus")
        #expect(ClaudeSettings.savedModel(in: try file(#"{"model": "downshift"}"#)) == nil)
        #expect(ClaudeSettings.savedModel(in: try file("{}")) == nil)
        #expect(ClaudeSettings.savedModel(in: try file("not json")) == nil)
        #expect(ClaudeSettings.savedModel(in: URL(fileURLWithPath: "/nonexistent/settings.json")) == nil)
    }

    @Test func restoresThePreviousModelWhenTheSentinelWasSaved() throws {
        let url = try file("""
            {
              "model": "downshift",
              "permissions": {
                "deny": [
                  "Bash(rm*)"
                ]
              }
            }

            """)
        #expect(ClaudeSettings.restoreSavedModel("opus", in: url))
        #expect(try contents(url) == """
            {
              "model": "opus",
              "permissions": {
                "deny": [
                  "Bash(rm*)"
                ]
              }
            }

            """)
    }

    @Test func removesTheSentinelWhenThereWasNoPreviousModel() throws {
        let url = try file(#"{"theme":"dark","model":"downshift","z":1}"#)
        #expect(ClaudeSettings.restoreSavedModel(nil, in: url))
        // Compact stays compact, key order is kept, and no newline is added.
        #expect(try contents(url) == #"{"theme":"dark","z":1}"#)
    }

    @Test func leavesARealModelTheUserChoseDuringTheSessionAlone() throws {
        let url = try file(#"{"model": "claude-opus-4-6"}"#)
        #expect(!ClaudeSettings.restoreSavedModel("sonnet", in: url))
        #expect(try contents(url) == #"{"model": "claude-opus-4-6"}"#)
    }

    @Test func aMissingOrUnreadableSettingsFileIsNotAnError() throws {
        #expect(!ClaudeSettings.restoreSavedModel("opus", in: URL(fileURLWithPath: "/nonexistent/nope/settings.json")))
        let broken = try file("{\"model\": \"downshift\"")
        #expect(!ClaudeSettings.restoreSavedModel("opus", in: broken))
    }

    @Test func keepsPermissionsAndFollowsSymlinks() throws {
        let url = try file("{\n    \"model\": \"downshift\"\n}\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let link = url.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)

        #expect(ClaudeSettings.restoreSavedModel("sonnet", in: link))
        #expect(try contents(url) == "{\n    \"model\": \"sonnet\"\n}\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == url.path)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}
