import Foundation
import JevCore
import Testing
@testable import JevHosts
@testable import JevProxy

@Suite struct JevRoutingTests {
    let route = RouteRequest(prompt: "rename tmp", current: "claude-a", contextTokens: 50_000, models: [
        RoutableModel(id: "claude-a", tier: .fast, description: "A"),
        RoutableModel(id: "claude-b", tier: .strong, description: "B"),
    ])

    func reply(choice: String) throws -> SystemOneResult {
        func score(_ value: Int) -> String {
            #"{"type":"score","score":\#(value),"legend":{"0":"none"},"probabilities":{"\#(value)":1},"confidence":0.5}"#
        }
        let text = """
            {"model":"jev-1","answers":{
              "model":{"type":"choice","choice":"\(choice)","probabilities":{"\(choice)":0.75},"confidence":0.75},
              "task_complexity":\(score(3)),"reasoning_required":\(score(6)),"tool_complexity":\(score(9))},
             "usage":{"input_tokens":1,"output_tokens":1}}
            """
        return try SystemOneResult(json: JSONValue.parse(Data(text.utf8)))
    }

    func request() throws -> SystemOneRequest {
        try RoutingQuestion.request(prompt: route.prompt, currentModel: route.current, contextTokens: route.contextTokens,
                                    models: route.models.map { .init(id: $0.id, tier: $0.tier, description: $0.description) })
    }

    func outcome(_ result: SystemOneResult) -> JevOutcome {
        JevOutcome(result: result, host: "cloudflare", failure: nil, attempts: [], milliseconds: 42)
    }

    @Test func theChoiceAndMetricsMatchTheNodeRouter() throws {
        let result = try reply(choice: "claude-b")
        let (answer, problem) = JevRouting.answer(result, request: try request(), route: route, outcome: outcome(result))
        #expect(problem == nil)
        let routed = try #require(answer)
        #expect(routed.choice == "claude-b" && routed.confidence == 0.75)
        let metrics = try #require(routed.metrics)
        #expect(abs((metrics["taskComplexity"]?.doubleValue ?? 0) - 3.0 / 9) < 1e-9)
        #expect(abs((metrics["reasoningRequired"]?.doubleValue ?? 0) - 6.0 / 9) < 1e-9)
        #expect(metrics["toolComplexity"]?.doubleValue == 1)
        #expect(metrics["contextSize"]?.doubleValue == 0.25)
        #expect(metrics["ms"]?.intValue == 42)
        #expect(metrics["host"]?.stringValue == "cloudflare")
        #expect(routed.request == (try request()).json)
        #expect(routed.response == result.json)
    }

    @Test func aChoiceThatWasNotOfferedIsIgnored() throws {
        let result = try reply(choice: "claude-z")
        let (answer, problem) = JevRouting.answer(result, request: try request(), route: route, outcome: outcome(result))
        #expect(answer == nil)
        #expect(problem?.contains("claude-z") == true)
    }

    @Test func contextSizeIsCapped() throws {
        var big = route
        big.contextTokens = 900_000
        let result = try reply(choice: "claude-a")
        let (answer, _) = JevRouting.answer(result, request: try request(), route: big, outcome: outcome(result))
        #expect(answer?.metrics?["contextSize"]?.doubleValue == 1)
    }

    @Test func withoutHostsTheRouterFailsOpen() async {
        let router = JevRouting.router(JevClient(hosts: []))
        #expect(await router(route) == nil)
    }
}
