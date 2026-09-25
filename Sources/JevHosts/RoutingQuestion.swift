import JevCore

/// The Jev question set: one exact-model choice plus three complexity scores.
/// Ported from `config.mjs` (`QUESTIONS`, `GUIDANCE`, `questionForModels`) and the request
/// built in `router.mjs`; wording and key order are unchanged because they are the prompt.
public enum RoutingQuestion {
    public static let complexityScale: [JevPayload] = [
        "None", "Very low", "Low", "Some", "Moderate", "Moderate to high", "High", "Very high", "Severe", "Extreme",
    ]

    public static var complexityMaxScore: Int { complexityScale.count - 1 }

    public struct Model: Sendable, Hashable {
        public var id: String
        public var tier: Tier
        public var description: String?

        public init(id: String, tier: Tier, description: String? = nil) {
            self.id = id
            self.tier = tier
            self.description = description
        }
    }

    // `score` only throws for fewer than two criteria; the scale has ten.
    static func complexity(_ instructions: String) -> JevQuestion {
        .score(instructions: .text(instructions), criteria: complexityScale)
    }

    public static let scores: [(String, JevQuestion)] = [
        ("task_complexity", complexity(
            "How complex is the coding task overall, including ambiguity, scope, and blast radius?")),
        ("reasoning_required", complexity(
            "How much reasoning is required to complete the request correctly in one pass?")),
        ("tool_complexity", complexity(
            "How complex is the tool use required, from no tools to many coordinated or stateful operations?")),
    ]

    static func guidance(_ tier: Tier) -> [(String, JSONValue)] {
        switch tier {
        case .fast:
            [("what", "Trivial, mechanical, or purely factual work."),
             ("signals", ["Rename, reformat, comment, or run one obvious command"]),
             ("not_for", "Design judgement or multi-file reasoning.")]
        case .balanced:
            [("what", "Ordinary day-to-day engineering with a clear, bounded shape."),
             ("signals", ["Implement a specified function, test existing behaviour, or fix an understood local bug"]),
             ("not_for", "Open-ended architecture, subtle concurrency, or unknown-cause debugging.")]
        case .strong:
            [("what", "Hard reasoning, ambiguity, or high blast radius."),
             ("signals", ["Unknown-cause debugging, cross-module design, security, auth, concurrency, or migrations"]),
             ("not_for", "Routine work with a clear implementation.")]
        case .long:
            [("what", "Very large or long-running work beyond a normal focused session."),
             ("signals", ["Whole-repo migration, unusually large context, or multi-hour autonomous execution"]),
             ("not_for", "Anything a strong model can finish in one focused session.")]
        }
    }

    /// The exact-model choice, built from the models available to this account and CLI.
    public static func modelChoice(_ models: [Model]) -> JevQuestion {
        .choice(
            instructions: [
                "Pick the cheapest exact model that can fully complete this coding request in one pass, without retrying on a stronger model.",
                "Treat different model versions as separate choices. Judge required reasoning, not requested reply length.",
            ],
            criteria: models.map { model in
                (label: model.id,
                 description: .object(JSONObject([("model", .string(model.description ?? model.id))] + guidance(model.tier))))
            })
    }

    /// The full request for one fresh user turn.
    public static func request(
        prompt: String, currentModel: String, contextTokens: Int, models: [Model]
    ) throws -> SystemOneRequest {
        let state: JevPayload = .object([
            "request": .string(prompt),
            "session": ["current_model": .string(currentModel), "context_tokens": .number(contextTokens)],
            "environment": ["available_models": .array(models.map { .string($0.id) })],
        ])
        return try SystemOneRequest(state: state, questions: scores + [("model", modelChoice(models))])
    }
}
