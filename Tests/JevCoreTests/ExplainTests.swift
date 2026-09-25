import Foundation
import Testing
@testable import JevCore

/// Port of `test/explain.test.mjs`. The skill check moves to the skills phase, where the
/// SKILL.md templates are generated.
struct ExplainTests {
    func status(_ json: String) throws -> JSONObject { try #require(try JSONValue.parse(json).objectValue) }

    @Test func formatsTheLastRoutingDecision() throws {
        let output = Explain.format(try status("""
            {
              "prompt": "Explain the router architecture",
              "tier": "balanced",
              "model": "claude-sonnet-5",
              "confidence": 0.94,
              "reason": "jev",
              "jev": {
                "request": { "state": { "session": { "current_model": "claude-haiku-4-5", "context_tokens": 6200 } } },
                "response": { "answers": { "model": { "choice": "claude-sonnet-5" } } }
              },
              "metrics": { "taskComplexity": 0.82, "reasoningRequired": 0.91, "toolComplexity": 0.64, "contextSize": 0.31 }
            }
            """))

        #expect(output.contains("Task complexity     0.82"))
        #expect(output.contains("Prompt: Explain the router"))
        #expect(output.contains("Current model: CLAUDE-HAIKU-4-5"))
        #expect(output.contains("Context tokens: 6200"))
        #expect(output.contains("Recommended model: CLAUDE-SONNET-5"))
        #expect(output.contains("Selected model: CLAUDE-SONNET-5"))
        #expect(output.contains("Confidence: 94%"))
        #expect(output.contains("Decision: Jev recommendation"))

        // Every line is exactly the box width.
        let lines = output.split(separator: "\n")
        #expect(lines.allSatisfy { $0.count == Explain.width + 2 })
    }

    @Test func recommendationComesFromJevNotTheFinalTier() throws {
        // Bug #1: the recommendation must be Jev's answer even when policy overrode it.
        let output = Explain.format(try status("""
            {"tier": "balanced", "reason": "low-confidence-capped", "confidence": 0.2,
             "jev": {"response": {"answers": {"model": {"choice": "claude-fable-5-1"}}}}}
            """))
        #expect(output.contains("Recommended model: CLAUDE-FABLE-5-1"))
        #expect(output.contains("Selected model: BALANCED"))
        #expect(output.contains("Decision: low confidence; capped"))
    }

    @Test func showsTheConcreteProviderModelWhenAvailable() throws {
        let output = Explain.format(try status(#"{"tier": "fast", "model": "gpt-5.6-luna", "confidence": 0.99}"#))
        #expect(output.contains("Selected model: GPT-5.6-LUNA"))
        #expect(output.contains("Task complexity     n/a"))
    }

    @Test func noDecisionAndManualMessages() throws {
        #expect(Explain.format(nil).contains("no routing decision"))
        #expect(Explain.format(try status(#"{"manual": true, "at": 1}"#)).contains("selected a model manually"))
    }

    @Test func longPromptsWrapAndLongWordsAreCut() {
        let rows = Explain.wrapped("Prompt: ", "fix the flaky websocket test in the proxy package please \(String(repeating: "x", count: 50))")
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.count == Explain.width + 2 })
        #expect(rows[0] == "│ Prompt: fix the flaky websocket test in the  │")
        #expect(rows[2] == "│ \(String(repeating: "x", count: Explain.width - 2)) │")
    }

    @Test func decisionLabels() {
        #expect(Explain.decision("override/no-change") == "prompt override")
        #expect(Explain.decision("jev-unavailable") == "Jev unavailable; held")
        #expect(Explain.decision("downgrade-not-worth-cache-rebuild") == "cache rebuild avoided")
        #expect(Explain.decision("jev+unavailable") == "nearest available tier")
    }
}
