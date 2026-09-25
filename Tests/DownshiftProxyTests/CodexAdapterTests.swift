import Foundation
import DownshiftCore
import NIOCore
import Testing
@testable import DownshiftProxy

@Suite struct CodexAdapterTests {
    let adapter = CodexAdapter()

    @Test func readsOnlyFreshUserTurns() throws {
        var body: JSONValue = try JSONValue.parse(#"""
        {"input":[
          {"type":"additional_tools","role":"developer","tools":[{}]},
          {"role":"user","content":[{"type":"input_text","text":"Fix the bug"}]},
          {"role":"user","content":[{"type":"input_text","text":"<system_reminder>tools</system_reminder>"}]},
          {"role":"user","content":"<environment_context><current_date>2026-09-17</current_date></environment_context>"}
        ]}
        """#)
        #expect(adapter.newTurnPrompt(body) == "Fix the bug")
        #expect(adapter.isAgentTurn(body))
        guard case .array(var input)? = body["input"] else { Issue.record("no input"); return }
        input.append(["type": "function_call_output", "call_id": "1", "output": "done"])
        body["input"] = .array(input)
        #expect(adapter.newTurnPrompt(body) == nil)
        #expect(!adapter.isAgentTurn(body))
    }

    @Test func titleCallsAreNotTurns() throws {
        let byPrompt = try JSONValue.parse(#"""
        {"input":[
          {"type":"additional_tools","role":"developer","tools":[{}]},
          {"role":"user","content":"Generate a concise, single-line task title of at most 36 characters"},
          {"role":"user","content":"<environment_context><timezone>Asia/Calcutta</timezone></environment_context>"}
        ]}
        """#)
        #expect(adapter.newTurnPrompt(byPrompt) == nil)
        #expect(CodexAdapter.isAuxiliaryPrompt("Generate a concise, single-line task title of at most 36 characters"))

        // The app's own title call looks like a turn; only its metadata gives it away.
        let byMetadata = try JSONValue.parse(#"""
        {"client_metadata":{"x-codex-turn-metadata":"{\"turn_trigger\":\"thread_title\"}"},
         "input":[{"type":"additional_tools","role":"developer","tools":[{}]},
                  {"role":"user","content":[{"type":"input_text","text":"name this thread"}]}]}
        """#)
        #expect(adapter.newTurnPrompt(byMetadata) == nil)
        #expect(!adapter.isAgentTurn(byMetadata))
    }

    /// Against the captured Codex app requests, when present (they hold private prompts and
    /// are never committed): every app POST carries the "lite" header, so only the turn
    /// metadata tells the title call from the real turn.
    @Test func capturedAppRequestsSplitIntoTitleAndTurn() throws {
        let apps = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/apps")
        let files = ((try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-POST-codex_responses.request.body") }
        for file in files {
            let body = try JSONValue.parse(try Data(contentsOf: file))
            let trigger = CodexAdapter.turnMetadata(body)?["turn_trigger"]?.stringValue
            #expect((adapter.newTurnPrompt(body) == nil) == (trigger == "thread_title"), "\(file.lastPathComponent)")
        }
    }

    @Test func keepsSubAgentStateSeparate() throws {
        func body(_ key: String) -> JSONValue {
            ["prompt_cache_key": .string(key), "input": [["role": "user", "content": "same prompt"]]]
        }
        #expect(adapter.conversationKey(body("main")) != adapter.conversationKey(body("sub-agent")))
        #expect(adapter.conversationKey(body("main")) == adapter.conversationKey(body("main")))
        #expect(adapter.conversationKey(body("main")).count == 12)
    }

    @Test func sessionComesFromClientMetadata() {
        #expect(adapter.sessionOf(["client_metadata": ["session_id": "abc"]]) == "abc")
        #expect(adapter.sessionOf([:]) == "")
    }

    @Test func addsJevRouterToTheCatalog() throws {
        let catalog: JSONValue = ["models": [[
            "slug": "gpt-5.6-terra", "display_name": "GPT-5.6-Terra", "visibility": "list",
            "supported_in_api": true, "priority": 2, "prefer_websockets": true,
        ]]]
        let result = try #require(adapter.addingJevModel(catalog))
        let models = try #require(result["models"]?.arrayValue)
        #expect(models[0]["slug"]?.stringValue == "downshift")
        #expect(models[0]["display_name"]?.stringValue == "Dynamic (Downshift)")
        #expect(models[0]["prefer_websockets"] == .bool(false))
        #expect(models[1]["slug"]?.stringValue == "gpt-5.6-terra")
        #expect(models[1]["prefer_websockets"] == .bool(true))
        // Already there: nothing to add.
        #expect(adapter.addingJevModel(result) == nil)
    }

    @Test func subscriptionAuthGoesToChatGPTAndKeysToTheAPI() {
        #expect(CodexAdapter.usesChatGPT(path: "/responses", accountHeader: "acct"))
        #expect(!CodexAdapter.usesChatGPT(path: "/responses", accountHeader: nil))
        #expect(CodexAdapter.usesChatGPT(path: "/models", accountHeader: nil))
    }

    @Test func clampsUnsupportedReasoningEffort() {
        var body: JSONValue = ["model": "downshift", "reasoning": ["effort": "max"]]
        let catalog: [JSONValue] = [[
            "slug": "gpt-5.6-luna", "default_reasoning_level": "medium",
            "supported_reasoning_levels": [["effort": "medium"]],
        ]]
        adapter.apply(&body, tier: .fast, model: "gpt-5.6-luna", catalog: catalog)
        #expect(body["model"]?.stringValue == "gpt-5.6-luna")
        #expect(body["reasoning"]?["effort"]?.stringValue == "medium")
    }

    @Test func offersExactVisibleModels() {
        let catalog: [JSONValue] = [
            ["slug": "downshift", "display_name": "Jev Router"],
            ["slug": "gpt-5.6-terra", "display_name": "GPT-5.6-Terra"],
            ["slug": "gpt-5.6-sol", "display_name": "GPT-5.6-Sol", "context_window": 400000],
            ["slug": "gpt-5.6-sol-reviewer", "visibility": "hide"],
            ["slug": "gpt-5.6-internal", "supported_in_api": false],
        ]
        let models = adapter.models(catalog: catalog)
        #expect(models.map(\.id) == ["gpt-5.6-terra", "gpt-5.6-sol"])
        #expect(models.map(\.tier) == [.balanced, .strong])
        #expect(models[1].description == "GPT-5.6-Sol; 400000 context tokens")
        // No catalog yet: one configured model per tier.
        #expect(adapter.models(catalog: []).map(\.id) == Tier.allCases.map { CodexModel.id(for: $0, environment: [:]) })
    }

    @Test func decisionIsANativeCommentaryMessage() {
        let frames = CodexAdapter.decisionFrames(RoutingOutcome(tier: .strong, model: "gpt-5.6-sol", confidence: 0.91, reason: "jev"))
        #expect(frames.contains("event: response.output_item.added\n"))
        #expect(frames.contains("event: response.output_text.delta\n"))
        #expect(frames.contains("event: response.output_item.done\n"))
        #expect(frames.contains(#""phase":"commentary""#))
        #expect(frames.contains("[Jev] routed this turn to gpt-5.6-sol (jev, confidence 0.91)."))
        #expect(frames.hasSuffix("\n\n"))

        let unavailable = CodexAdapter.decisionEvents(
            RoutingOutcome(tier: .balanced, model: "gpt-5.6-terra", confidence: nil, reason: "jev-unavailable/no-change"), id: "x")
        let text = unavailable[2]["item"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("using gpt-5.6-terra"))
        #expect(text.contains("dshift setup"))
        #expect(unavailable[1]["item_id"]?.stringValue == "x")
    }
}

@Suite struct SSEInjectorTests {
    static let frames = ByteBuffer(string: "event: jev\ndata: {}\n\n")

    func run(_ chunks: [[UInt8]]) -> (bytes: [UInt8], injected: Bool) {
        var injector = SSEInjector(frames: Self.frames)
        var out: [UInt8] = []
        for chunk in chunks {
            for buffer in injector.feed(ByteBuffer(bytes: chunk)) { out += buffer.readableBytesView }
        }
        if let rest = injector.finish() { out += rest.readableBytesView }
        return (out, injector.injected)
    }

    /// Plan bug #3: a multi-byte character split across chunks must come out intact.
    @Test func keepsAUTF8CharacterSplitAcrossChunks() {
        let first = Array("event: response.created\ndata: {\"t\":\"".utf8)
        let euro = Array("€".utf8) // E2 82 AC
        let tail = Array("\"}\n\nevent: response.completed\ndata: {\"t\":\"日本\"}\n\n".utf8)
        let japanese = Array("日".utf8)
        let chunks: [[UInt8]] = [
            first + euro[0..<1], Array(euro[1...]) + tail[0..<3], Array(tail[3...]) + japanese[0..<2], Array(japanese[2...]),
        ]
        let (bytes, injected) = run(chunks)
        let expected = first + euro + Array("\"}\n\n".utf8) + Array(Self.frames.readableBytesView)
            + Array("event: response.completed\ndata: {\"t\":\"日本\"}\n\n".utf8) + japanese
        #expect(injected)
        #expect(bytes == expected)
        #expect(String(decoding: bytes, as: UTF8.self).contains("€"))
    }

    @Test func findsTheFirstEventAcrossChunks() {
        let (bytes, injected) = run([Array("event: a\n".utf8), Array("data: 1\n".utf8), Array("\nevent: b\ndata: 2\n\n".utf8)])
        #expect(injected)
        #expect(String(decoding: bytes, as: UTF8.self) == "event: a\ndata: 1\n\nevent: jev\ndata: {}\n\nevent: b\ndata: 2\n\n")
    }

    @Test func leavesNonSSEAlone() {
        let json = Array(#"{"error":{"message":"x"}}"#.utf8)
        let (bytes, injected) = run([json])
        #expect(!injected)
        #expect(bytes == json)

        let (paragraphs, injectedIntoText) = run([Array("hello\n\nworld".utf8)])
        #expect(!injectedIntoText)
        #expect(String(decoding: paragraphs, as: UTF8.self) == "hello\n\nworld")
    }
}
