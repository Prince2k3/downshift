import Foundation
import DownshiftCore
import Testing
@testable import JevHosts
@testable import DownshiftProxy

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

    @Test func theChoiceIsRead() throws {
        let result = try reply(choice: "claude-b")
        let (answer, problem) = JevRouting.answer(result, route: route)
        #expect(problem == nil)
        let routed = try #require(answer)
        #expect(routed.choice == "claude-b" && routed.confidence == 0.75)
        #expect(routed.response == result.json)
    }

    @Test func aChoiceThatWasNotOfferedIsIgnored() throws {
        let result = try reply(choice: "claude-z")
        let (answer, problem) = JevRouting.answer(result, route: route)
        #expect(answer == nil)
        #expect(problem?.contains("claude-z") == true)
    }

    @Test func withoutHostsTheRouterFailsOpen() async {
        let router = JevRouting.router(JevClient(hosts: []))
        #expect(await router(route) == nil)
    }
}
