import DownshiftCore
import JevHosts

/// Connects the routing engine to Jev through a `JevClient`.
public enum JevRouting {
    public static func router(_ client: JevClient) -> JevRouter {
        { request in
            let outcome = await ask(client, request)
            return outcome.answer
        }
    }

    /// Everything one routing call did, for the router and for `dshift hosts test`.
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
        let (answer, problem) = answer(result, route: route)
        return Result(outcome: outcome, request: request, answer: answer, problem: problem)
    }

    /// Reads the model choice out of a validated result.
    static func answer(_ result: SystemOneResult, route: RouteRequest) -> (RouteAnswer?, String?) {
        guard let pick = result.answers["model"], let choice = pick.choice else {
            return (nil, "the reply has no model choice")
        }
        guard route.models.contains(where: { $0.id == choice }) else {
            return (nil, "Jev chose \(choice), which was not offered")
        }
        return (RouteAnswer(choice: choice, confidence: pick.confidence ?? 0, response: result.json), nil)
    }
}
