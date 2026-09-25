import JevCore
import JevHosts

/// Connects the routing engine to Jev through a `JevClient`.
public enum JevRouting {
    /// Context sizes are reported to `jev explain` as a fraction of this many tokens.
    public static let contextScale = 200_000

    public static func router(_ client: JevClient) -> JevRouter {
        { request in
            let outcome = await ask(client, request)
            return outcome.answer
        }
    }

    /// Everything one routing call did, for the router and for `jev hosts test`.
    public struct Result: Sendable {
        public var outcome: JevOutcome?
        public var request: SystemOneRequest?
        public var answer: RouteAnswer?
        /// Why there is no answer when Jev did reply: the choice is missing or not offered.
        public var problem: String?
    }

    public static func ask(_ client: JevClient, _ route: RouteRequest) async -> Result {
        let models = route.models.map { RoutingQuestion.Model(id: $0.id, tier: $0.tier, description: $0.description) }
        guard let request = try? RoutingQuestion.request(
            prompt: route.prompt, currentModel: route.current, contextTokens: route.contextTokens, models: models)
        else { return Result(problem: "the routing question could not be built") }
        let outcome = await client.ask(request)
        guard let result = outcome.result else { return Result(outcome: outcome, request: request) }
        let (answer, problem) = answer(result, request: request, route: route, outcome: outcome)
        return Result(outcome: outcome, request: request, answer: answer, problem: problem)
    }

    /// Reads the model choice and scores out of a validated result.
    static func answer(_ result: SystemOneResult, request: SystemOneRequest, route: RouteRequest,
                       outcome: JevOutcome) -> (RouteAnswer?, String?) {
        guard let pick = result.answers["model"], let choice = pick.choice else {
            return (nil, "the reply has no model choice")
        }
        guard route.models.contains(where: { $0.id == choice }) else {
            return (nil, "Jev chose \(choice), which was not offered")
        }
        var metrics = JSONObject()
        let maxScore = Double(RoutingQuestion.complexityMaxScore)
        for (key, name) in [("task_complexity", "taskComplexity"), ("reasoning_required", "reasoningRequired"),
                            ("tool_complexity", "toolComplexity")] {
            if let score = result.answers[key]?.score { metrics[name] = .number(score / maxScore) }
        }
        metrics["contextSize"] = .number(min(Double(route.contextTokens) / Double(contextScale), 1))
        metrics["ms"] = .number(outcome.milliseconds)
        if let host = outcome.host { metrics["host"] = .string(host) }
        let answer = RouteAnswer(choice: choice, confidence: pick.confidence ?? 0, metrics: .object(metrics),
                                 request: request.json, response: result.json)
        return (answer, nil)
    }
}
