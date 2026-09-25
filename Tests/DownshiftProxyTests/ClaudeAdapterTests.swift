import DownshiftCore
import Testing
@testable import DownshiftProxy

/// Port of the pure half of `test/proxy.test.mjs`. Status round-trips live in StatusStoreTests.
struct ClaudeAdapterTests {
    func json(_ text: String) throws -> JSONValue { try JSONValue.parse(text) }
    func withTools(_ messages: String) throws -> JSONValue { try json(#"{"tools": [{"name": "Bash"}], "messages": \#(messages)}"#) }

    // MARK: Sentinel and tiers

    @Test func onlyTheSentinelIsRouted() {
        #expect(RouterModel.isRouted("downshift"))
        #expect(!RouterModel.isRouted("claude-opus-4-6"), "a model the user picked is theirs")
        #expect(!RouterModel.isRouted("claude-haiku-4-5-20251001"), "internal Haiku calls pass through")
        #expect(!RouterModel.isRouted(nil))
        #expect(ClaudeModel.tier(of: "downshift") == nil)
        #expect(ClaudeModel.tier(of: "claude-sonnet-5") == .balanced)
    }

    @Test func recognisesOlderVersionsWithinATier() {
        #expect(ClaudeModel.tier(of: "claude-sonnet-4-6") == .balanced)
        #expect(ClaudeModel.tier(of: "claude-haiku-4-5-20251001") == .fast)
        #expect(ClaudeModel.tier(of: "claude-opus-4-1") == .strong)
        #expect(ClaudeModel.tier(of: "claude-fable-5-1[1m]") == .long)
        #expect(ClaudeModel.tier(of: "gpt-9") == nil)
    }

    @Test func readsTheSessionIdOutOfMetadata() throws {
        let sid = "11111111-2222-4333-8444-555555555555"
        let body: JSONValue = ["metadata": ["user_id": .string(#"{"session_id":"\#(sid)"}"#)]]
        #expect(ClaudeAdapter.sessionOf(body) == sid)
        #expect(ClaudeAdapter.sessionOf(["metadata": ["user_id": "not-json"]]) == "")
        #expect(ClaudeAdapter.sessionOf([:]) == "")
    }

    // MARK: Catalog

    @Test func keepsAccountModelVersionsAsSeparateChoices() throws {
        let models = ClaudeAdapter.models(catalog: [
            ["id": "claude-opus-5", "display_name": "Claude Opus 5", "created_at": "2026-05-01T00:00:00Z", "max_input_tokens": 1000000],
            ["id": "claude-opus-4-8", "display_name": "Claude Opus 4.8"],
            ["id": "some-embedding-model"],
        ])
        #expect(models.map(\.id) == ["claude-opus-5", "claude-opus-4-8"])
        #expect(models.map(\.tier) == [.strong, .strong])
        #expect(models[0].description == "Claude Opus 5; released 2026-05-01; 1000000 input tokens")
        #expect(ClaudeAdapter.model(for: .strong, in: models) == "claude-opus-5")
        #expect(ClaudeAdapter.model(for: .fast, in: models) == "claude-haiku-4-5-20251001")
    }

    @Test func staticIdsAreTheColdStartFallback() {
        #expect(ClaudeAdapter.models(catalog: []).map(\.id) == ClaudeModel.all.map(\.id))
    }

    // MARK: sanitizeSchema

    func sanitized(_ text: String) throws -> JSONValue {
        var node = try json(text)
        ClaudeAdapter.sanitizeSchema(&node)
        return node
    }

    @Test func convertsABooleanExclusiveMinimumIntoANumber() throws {
        let schema = try sanitized(#"{"type": "object", "properties": {"topN": {"minimum": 0, "exclusiveMinimum": true}}}"#)
        #expect(schema["properties"]?["topN"] == ["exclusiveMinimum": 0])
    }

    @Test func dropsAFalseExclusiveMaximumAndKeepsTheBound() throws {
        let schema = try sanitized(#"{"properties": {"n": {"maximum": 10, "exclusiveMaximum": false}}}"#)
        #expect(schema["properties"]?["n"] == ["maximum": 10])
    }

    @Test func dropsATrueExclusiveBoundWithNoNumberToMove() throws {
        #expect(try sanitized(#"{"exclusiveMinimum": true}"#) == [:])
    }

    @Test func leavesAValidNumericBoundAlone() throws {
        #expect(try sanitized(#"{"properties": {"n": {"exclusiveMinimum": 5}}}"#)["properties"]?["n"]?["exclusiveMinimum"] == 5)
    }

    @Test func reachesSchemasNestedInArraysAndSubObjects() throws {
        let schema = try sanitized(#"{"anyOf": [{"items": {"minimum": 1, "exclusiveMinimum": true}}]}"#)
        #expect(schema["anyOf"]?[0]?["items"] == ["exclusiveMinimum": 1])
    }

    @Test func survivesNullAndPrimitiveNodes() throws {
        #expect(try sanitized("null") == .null)
        #expect(try sanitized(#"{"a": null, "b": 3, "c": "x"}"#) == ["a": nil, "b": 3, "c": "x"])
    }

    @Test func sanitizesEveryToolInputSchema() throws {
        var body = try json(#"{"tools": [{"name": "a", "input_schema": {"minimum": 2, "exclusiveMinimum": true}}, {"name": "b"}]}"#)
        ClaudeAdapter.sanitizeTools(&body)
        #expect(body["tools"]?[0]?["input_schema"] == ["exclusiveMinimum": 2])
        #expect(body["tools"]?[1] == ["name": "b"])
    }

    // MARK: newTurnPrompt

    @Test func readsAPlainStringPrompt() throws {
        #expect(ClaudeAdapter.newTurnPrompt(try withTools(#"[{"role": "user", "content": "fix the bug"}]"#)) == "fix the bug")
    }

    @Test func readsATextBlockPrompt() throws {
        let body = try withTools(#"[{"role": "user", "content": [{"type": "text", "text": "fix the bug"}]}]"#)
        #expect(ClaudeAdapter.newTurnPrompt(body) == "fix the bug")
    }

    @Test func ignoresAToolResultContinuation() throws {
        let body = try withTools("""
            [{"role": "user", "content": "fix the bug"},
             {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]},
             {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "done"}]}]
            """)
        #expect(ClaudeAdapter.newTurnPrompt(body) == nil)
    }

    @Test func ignoresAuxiliaryCallsWithoutTools() throws {
        #expect(ClaudeAdapter.newTurnPrompt(try json(#"{"messages": [{"role": "user", "content": "summarise this"}]}"#)) == nil)
    }

    @Test func ignoresALastMessageFromTheAssistant() throws {
        #expect(ClaudeAdapter.newTurnPrompt(try withTools(#"[{"role": "assistant", "content": "thinking"}]"#)) == nil)
    }

    @Test func ignoresAnEmptyPrompt() throws {
        #expect(ClaudeAdapter.newTurnPrompt(try withTools(#"[{"role": "user", "content": "   "}]"#)) == nil)
    }

    @Test func survivesAMalformedBody() throws {
        #expect(ClaudeAdapter.newTurnPrompt(.null) == nil)
        #expect(ClaudeAdapter.newTurnPrompt([:]) == nil)
        #expect(ClaudeAdapter.newTurnPrompt(try json(#"{"tools": [], "messages": []}"#)) == nil)
        #expect(ClaudeAdapter.newTurnPrompt(try withTools(#"[{"role": "user", "content": 7}]"#)) == nil)
    }

    @Test func stripsSystemReminders() throws {
        let body = try withTools(#"[{"role": "user", "content": "fix the bug\n<system-reminder>be careful\nabout things</system-reminder>"}]"#)
        #expect(ClaudeAdapter.newTurnPrompt(body) == "fix the bug")
    }

    @Test func aPromptThatIsOnlyASystemReminderIsNotATurn() throws {
        #expect(ClaudeAdapter.newTurnPrompt(try withTools(#"[{"role": "user", "content": "<system-reminder>noise</system-reminder>"}]"#)) == nil)
    }

    // MARK: applyTier

    @Test func routingToFastStripsFieldsHaikuCannotAccept() throws {
        var body = try json("""
            {"model": "claude-sonnet-4-6", "thinking": {"type": "adaptive"}, "output_config": {"effort": "medium"},
             "context_management": {"edits": [{"type": "clear_thinking_20251015", "keep": "all"}]}}
            """)
        ClaudeAdapter.applyTier(&body, tier: .fast)
        #expect(body == ["model": "claude-haiku-4-5-20251001"])
    }

    @Test func routingToFastKeepsUnrelatedContextManagementAndOutputConfig() throws {
        var body = try json("""
            {"model": "claude-sonnet-4-6", "output_config": {"effort": "low", "format": "x"},
             "context_management": {"edits": [{"type": "clear_tool_uses_20250919"}, {"type": "clear_thinking_20251015"}]}}
            """)
        ClaudeAdapter.applyTier(&body, tier: .fast)
        #expect(body["context_management"] == ["edits": [["type": "clear_tool_uses_20250919"]]])
        #expect(body["output_config"] == ["format": "x"])
    }

    @Test func routingToStrongLeavesThinkingAndEffortIntact() throws {
        var body = try json(#"{"model": "claude-sonnet-4-6", "thinking": {"type": "adaptive"}, "output_config": {"effort": "medium"}}"#)
        ClaudeAdapter.applyTier(&body, tier: .strong)
        #expect(body["model"] == "claude-opus-5")
        #expect(body["thinking"] == ["type": "adaptive"])
        #expect(body["output_config"] == ["effort": "medium"])
    }

    @Test func anExactModelOverridesTheTierDefault() throws {
        var body = try json(#"{"model": "downshift"}"#)
        ClaudeAdapter.applyTier(&body, tier: .strong, model: "claude-opus-4-8")
        #expect(body["model"] == "claude-opus-4-8")
    }

    // MARK: conversationKey

    @Test func aConversationKeepsOneKeyAsItGrowsAndDiffersFromASubAgent() throws {
        let main = try json(#"{"messages": [{"role": "user", "content": "main task"}]}"#)
        let grown = try json(#"{"messages": [{"role": "user", "content": "main task"}, {"role": "assistant", "content": "ok"}]}"#)
        let sub = try json(#"{"messages": [{"role": "user", "content": "sub-agent task"}]}"#)
        #expect(ClaudeAdapter.conversationKey(main) == ClaudeAdapter.conversationKey(grown))
        #expect(ClaudeAdapter.conversationKey(main) != ClaudeAdapter.conversationKey(sub))
        #expect(ClaudeAdapter.conversationKey(main).count == 12)
    }

    @Test func matchesNodesKeyByteForByte() throws {
        // Node: sha1("|main task").slice(0, 12). The Swift port must hash the same input.
        let main = try json(#"{"messages": [{"role": "user", "content": "main task"}]}"#)
        #expect(ClaudeAdapter.conversationKey(main) == "b1089b56b9bf")
    }

    @Test func theKeyIgnoresTheMovingCacheControlBreakpoint() throws {
        let first = try json("""
            {"messages": [{"role": "user", "content": [
              {"type": "text", "text": "<system-reminder>x</system-reminder>"},
              {"type": "text", "text": "do the thing", "cache_control": {"type": "ephemeral", "ttl": "1h"}}]}]}
            """)
        let later = try json("""
            {"messages": [{"role": "user", "content": [
              {"type": "text", "text": "<system-reminder>x</system-reminder>"},
              {"type": "text", "text": "do the thing"}]},
              {"role": "assistant", "content": "working"}]}
            """)
        #expect(ClaudeAdapter.conversationKey(first) == ClaudeAdapter.conversationKey(later))
    }

    @Test func theSameOpeningInTwoSessionsGetsTwoKeys() {
        func body(_ id: String) -> JSONValue {
            ["metadata": ["user_id": .string(#"{"session_id":"\#(id)"}"#)], "messages": [["role": "user", "content": "same opening"]]]
        }
        #expect(ClaudeAdapter.conversationKey(body("a")) != ClaudeAdapter.conversationKey(body("b")))
    }

    @Test func theKeySurvivesMetadataThatIsNotJSON() {
        let body: JSONValue = ["metadata": ["user_id": "not-json"], "messages": [["role": "user", "content": "hi"]]]
        #expect(ClaudeAdapter.conversationKey(body).count == 12)
    }

    @Test func contextTokensAreAQuarterOfTheSerializedMessages() throws {
        // [{"role":"user","content":"abcd"}] is 34 characters.
        #expect(ClaudeAdapter.contextTokens(try json(#"{"messages": [{"role": "user", "content": "abcd"}]}"#)) == 9)
    }
}
