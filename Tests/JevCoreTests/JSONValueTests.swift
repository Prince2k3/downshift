import Foundation
import Testing
@testable import JevCore

@Suite struct JSONValueTests {
    @Test("compact JSON round-trips byte-for-byte", arguments: [
        #"{"b":1,"a":2,"c":{"z":true,"y":null,"x":[1,2.50,-0,1e10,1E-7]}}"#,
        #"{"model":"jev-router","messages":[{"role":"user","content":"héllo 🌍 \"q\" \\ \n\t\u0001"}]}"#,
        #"[]"#, #"{}"#, #""""#, #"0"#, #"-12.340e+05"#,
        #"{"dup":1,"dup":2}"#,
        #"{"tools":[{"name":"Bash","input_schema":{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"number"}},"required":["command"]}}]}"#,
    ])
    func roundTrip(_ text: String) throws {
        let value = try JSONValue.parse(text)
        #expect(value.serializedString() == text)
    }

    @Test func keyOrderIsPreserved() throws {
        let value = try JSONValue.parse(#"{"zeta":1,"alpha":2,"mid":3}"#)
        #expect(value.objectValue?.keys == ["zeta", "alpha", "mid"])
    }

    @Test func numbersKeepTheirLiteral() throws {
        let value = try JSONValue.parse(#"[1.0, 1e2, 0.1000, 12345678901234567890123]"#)
        #expect(value.serializedString() == "[1.0,1e2,0.1000,12345678901234567890123]")
    }

    @Test func editsReplaceInPlace() throws {
        var value = try JSONValue.parse(#"{"model":"jev-router","max_tokens":10,"stream":true}"#)
        value["model"] = "claude-sonnet-5"
        value["thinking"] = ["type": "adaptive"]
        value["stream"] = nil
        #expect(value.serializedString() == #"{"model":"claude-sonnet-5","max_tokens":10,"thinking":{"type":"adaptive"}}"#)
    }

    @Test func duplicateKeysReadLastLikeJSONParse() throws {
        let value = try JSONValue.parse(#"{"a":1,"a":2}"#)
        #expect(value["a"]?.intValue == 2)
    }

    @Test func escapesDecode() throws {
        let value = try JSONValue.parse(#"["é\/🌍","\ud800x"]"#)
        #expect(value[0]?.stringValue == "é/🌍")
        #expect(value[1]?.stringValue == "\u{FFFD}x")
        // Re-serialized in the canonical JSON.stringify form.
        #expect(value.serializedString() == "[\"é/🌍\",\"\u{FFFD}x\"]")
    }

    @Test("rejects malformed input", arguments: [
        "", "{", "[1,]", #"{"a":}"#, "01", "1.", "-", "+1", "tru", #""\x""#, "\"a\u{01}\"", "[1] 2", #"{"a" 1}"#,
    ])
    func rejects(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSONValue.parse(text) }
    }

    @Test func depthIsBounded() throws {
        func nested(_ n: Int) -> String { String(repeating: "[", count: n) + String(repeating: "]", count: n) }
        let deepest = try JSONValue.parse(nested(JSONValue.maxDepth))
        #expect(deepest.serializedString() == nested(JSONValue.maxDepth))
        #expect(deepest == deepest)
        #expect(throws: JSONParseError.self) { try JSONValue.parse(nested(JSONValue.maxDepth + 1)) }
        #expect(throws: JSONParseError.self) { try JSONValue.parse(nested(100_000)) }
    }

    @Test func whitespaceIsAccepted() throws {
        let value = try JSONValue.parse(" {\n \"a\" : [ 1 , 2 ] \r\n}\t")
        #expect(value.serializedString() == #"{"a":[1,2]}"#)
    }

    /// Captured request bodies (from `JEV_DUMP`) must round-trip exactly,
    /// so rewriting `model` can never reorder or re-escape anything else.
    @Test func capturedFixturesRoundTrip() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let files = (FileManager.default.enumerator(at: fixtures, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".request.body") }
        for file in files {
            let data = try Data(contentsOf: file)
            guard data.first == UInt8(ascii: "{") else { continue }
            let value = try JSONValue.parse(data)
            #expect(Data(value.serialized()) == data, "\(file.lastPathComponent) did not round-trip")
        }
    }
}
