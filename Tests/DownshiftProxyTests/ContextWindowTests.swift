import DownshiftCore
import Foundation
import Testing
@testable import DownshiftProxy

/// Claude Code is told the sentinel has the largest window any routed model offers, so the
/// proxy must never leave a conversation on a model too small for it.
@Suite struct ContextWindowTests {
    /// A conversation of about `tokens` tokens by the proxy's estimate (four characters each):
    /// a new turn carries them in its prompt, a follow-up in a tool result after the same
    /// opening prompt, so both belong to one conversation.
    func body(tokens: Int, session: String, followUp: Bool = false) -> JSONValue {
        let filler = JSONValue.string(String(repeating: "a", count: tokens * 4))
        var messages: [JSONValue] = [["role": "user", "content": followUp ? "start" : filler]]
        if followUp {
            messages.append(["role": "assistant", "content": [["type": "tool_use", "id": "x", "name": "t", "input": [:]]]])
            messages.append(["role": "user", "content": [["type": "tool_result", "tool_use_id": "x", "content": filler]]])
        }
        return ["model": "downshift", "tools": [["name": "t", "input_schema": ["type": "object"]]],
                "messages": .array(messages),
                "metadata": ["user_id": .string(#"{"session_id":"\#(session)"}"#)]]
    }

    @Test func catalogWindowsWinOverTheBuiltInOnes() {
        let catalog: [JSONValue] = [["id": "claude-haiku-4-5", "max_input_tokens": 150_000], ["id": "claude-sonnet-5"]]
        #expect(ClaudeAdapter.models(catalog: catalog).map(\.contextWindow) == [150_000, 1_000_000])
    }

    @Test func aTurnTooLongForJevsChoiceGoesToTheNearestModelThatFits() async throws {
        let spy = RouterSpy(RouteAnswer(choice: "claude-haiku-4-5-20251001", confidence: 0.95))
        let engine = RoutingEngine(baseline: .fast, available: Tier.allCases, router: spy.router, store: nil)
        var request = body(tokens: 190_000, session: "big")
        let outcome = try #require(await engine.process(&request))
        #expect(request["model"]?.stringValue == "claude-sonnet-5")
        #expect(outcome.tier == .balanced)
        #expect(outcome.reason.hasSuffix("+context"))
    }

    @Test func aFollowUpThatOutgrowsItsModelMovesUpAndStays() async throws {
        let spy = RouterSpy(RouteAnswer(choice: "claude-haiku-4-5-20251001", confidence: 0.95))
        let engine = RoutingEngine(baseline: .fast, available: Tier.allCases, router: spy.router, store: nil)
        var first: JSONValue = ["model": "downshift", "tools": [["name": "t", "input_schema": ["type": "object"]]],
                                "messages": [["role": "user", "content": "start"]],
                                "metadata": ["user_id": .string(#"{"session_id":"grow"}"#)]]
        await engine.process(&first)
        #expect(first["model"]?.stringValue == "claude-haiku-4-5-20251001")

        var followUp = body(tokens: 190_000, session: "grow", followUp: true)
        await engine.process(&followUp)
        #expect(followUp["model"]?.stringValue == "claude-sonnet-5")

        // The conversation now lives on the larger model, even for a short follow-up.
        var next = body(tokens: 10, session: "grow", followUp: true)
        await engine.process(&next)
        #expect(next["model"]?.stringValue == "claude-sonnet-5")
    }

    @Test func aConversationThatFitsIsLeftAlone() {
        let models = ClaudeAdapter.models(catalog: [])
        #expect(RoutingEngine.larger(than: "claude-haiku-4-5-20251001", tier: .fast, contextTokens: 100_000, in: models) == nil)
        #expect(RoutingEngine.larger(than: "claude-opus-5", tier: .strong, contextTokens: 5_000_000, in: models) == nil)
    }
}
