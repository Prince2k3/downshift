import Foundation
import DownshiftCore
import Testing
@testable import JevHosts

enum Fixture {
    static let models = [RoutingQuestion.Model(id: "claude-a", tier: .fast), RoutingQuestion.Model(id: "claude-b", tier: .strong)]

    static func request() throws -> SystemOneRequest {
        try RoutingQuestion.request(prompt: "rename tmp", currentModel: "claude-a", contextTokens: 50_000, models: models)
    }

    static func score(_ value: Int) -> String {
        #"{"type":"score","score":\#(value),"legend":{"0":"none","9":"extreme"},"probabilities":{"\#(value)":0.7},"confidence":0.7}"#
    }

    /// Jev's reply, exactly as the response schema defines it.
    static func reply(choice: String = "claude-b", model: String = "jev-1") -> String {
        """
        {"model":"\(model)","answers":{
          "model":{"type":"choice","choice":"\(choice)","probabilities":{"claude-a":0.1,"claude-b":0.9},"confidence":0.9},
          "task_complexity":\(score(3)),"reasoning_required":\(score(6)),"tool_complexity":\(score(9))},
         "usage":{"input_tokens":120,"output_tokens":4}}
        """
    }

    static func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    static func host(_ format: JevHost.WireFormat, url: String = "https://example.test/jev") -> JevHost {
        JevHost(id: format.rawValue, format: format, url: url, apiKey: "sk-test", model: "jev-latest")
    }
}

@Suite struct JevHostRequestTests {
    func header(_ request: JevHost.HTTPRequest, _ name: String) -> String? {
        request.headers.first { $0.name == name }?.value
    }

    @Test func systemOneAddsTheModelToTheBody() throws {
        let request = try Fixture.request()
        let call = Fixture.host(.systemOne).httpRequest(request)
        #expect(call.url == "https://example.test/jev")
        #expect(header(call, "authorization") == "Bearer sk-test")
        #expect(call.body["model"] == .string("jev-latest"))
        #expect(call.body["questions"] == request.json["questions"])
        #expect(header(call, "ai-model-id") == nil)
    }

    @Test func workersAISendsTheSchemaExactBody() throws {
        let request = try Fixture.request()
        let call = Fixture.host(.workersAI).httpRequest(request)
        #expect(call.body == request.json)
        #expect(JevRequestSchema.schema.validate(call.body).isEmpty)
    }

    @Test func vercelNamesTheModelInHeaders() throws {
        let request = try Fixture.request()
        let call = Fixture.host(.vercel).httpRequest(request)
        #expect(call.body == request.json)
        #expect(header(call, "ai-model-id") == "jev-latest")
        #expect(header(call, "ai-evaluation-model-specification-version") == "4")
        #expect(header(call, "ai-gateway-protocol-version") == "0.0.1")
    }
}

@Suite struct JevHostReplyTests {
    @Test func systemOneDropsHostExtras() throws {
        var body = try Fixture.json(Fixture.reply())
        body["id"] = "gen-1"
        body["provider"] = "typesafe"
        body["usage"]?["cost"] = .number(0.0001)
        let result = try SystemOneResult(json: Fixture.host(.systemOne).normalize(body))
        #expect(result.answers["model"]?.choice == "claude-b")
        #expect(result.inputTokens == 120)
    }

    @Test func systemOneFillsAMissingModel() throws {
        var body = try Fixture.json(Fixture.reply())
        body["model"] = nil
        let result = try SystemOneResult(json: Fixture.host(.systemOne).normalize(body))
        #expect(result.model == "jev-latest")
    }

    @Test func workersAIUnwrapsTheResult() throws {
        let body = try Fixture.json(#"{"result":\#(Fixture.reply()),"success":true,"errors":[],"messages":[]}"#)
        let result = try SystemOneResult(json: Fixture.host(.workersAI).normalize(body))
        #expect(result.answers["task_complexity"]?.score == 3)
    }

    @Test func workersAIFailureCarriesTheHostMessage() throws {
        let body = try Fixture.json(#"{"result":null,"success":false,"errors":[{"code":5007,"message":"No such model"}]}"#)
        #expect { try Fixture.host(.workersAI).normalize(body) } throws: { ($0 as? JevHost.ReplyError)?.message == "No such model" }
    }

    @Test func vercelMovesConfidenceAndUsage() throws {
        let body = try Fixture.json("""
            {"modelId":"typesafe-ai/jev","answers":{
               "model":{"type":"choice","choice":"claude-a","probabilities":{"claude-a":0.6,"claude-b":0.4}},
               "task_complexity":{"type":"score","score":2,"legend":{"0":"none"},"probabilities":{"2":1}},
               "flag":{"type":"noul","noul":0.3}},
             "providerMetadata":{"typesafe":{"confidence":{"model":0.6,"task_complexity":0.8,"flag":0.5}}},
             "usage":{"inputTokens":7,"outputTokens":1}}
            """)
        let normalized = try Fixture.host(.vercel).normalize(body)
        let result = try SystemOneResult(json: normalized)
        #expect(result.model == "typesafe-ai/jev")
        #expect(result.answers["model"]?.confidence == 0.6)
        #expect(result.answers["task_complexity"]?.confidence == 0.8)
        #expect(result.answers["flag"] == .noul(0.3))
        #expect(result.outputTokens == 1)
    }

    @Test func aReplyMissingRequiredFieldsFailsTheSchema() throws {
        // Like the scores in the upstream Vercel fixture: no legend, probabilities or confidence.
        let body = try Fixture.json(#"{"model":"m","answers":{"x":{"type":"score","score":2}},"usage":{"input_tokens":1,"output_tokens":1}}"#)
        #expect(throws: JevResponseError.self) { try SystemOneResult(json: Fixture.host(.systemOne).normalize(body)) }
    }

    @Test(arguments: [
        (#"{"errors":[{"message":"bad token"}]}"#, "bad token"),
        (#"{"error":{"message":"rate limited"}}"#, "rate limited"),
        (#"{"error":"nope"}"#, "nope"),
        (#"{"message":"m"}"#, "m"),
        (#"{"detail":"d"}"#, "d"),
    ])
    func errorMessages(body: String, message: String) throws {
        #expect(JevHost.errorMessage(try Fixture.json(body)) == message)
    }

    @Test func answersDecode() throws {
        let result = try SystemOneResult(json: Fixture.json(Fixture.reply()))
        guard case .score(let score, let legend, let probabilities, let confidence)? = result.answers["tool_complexity"] else {
            Issue.record("not a score"); return
        }
        #expect(score == 9 && legend["9"] == "extreme" && probabilities["9"] == 0.7 && confidence == 0.7)
        #expect(result.answers["model"]?.score == nil)
    }
}

@Suite struct HostPresetTests {
    func env(_ values: [String: String]) -> DownshiftEnvironment { DownshiftEnvironment(values: values) }

    @Test func nothingConfiguredMeansNoHost() {
        let resolution = HostPresets.resolve(environment: env([:]))
        #expect(resolution.hosts.isEmpty && resolution.problems.isEmpty)
    }

    @Test func cloudflareIsPreferredWhenSeveralAreConfigured() {
        let resolution = HostPresets.resolve(environment: env([
            "OPENROUTER_API_KEY": "or", "CLOUDFLARE_API_TOKEN": "cf", "CLOUDFLARE_ACCOUNT_ID": "abc123",
        ]))
        #expect(resolution.hosts.map(\.id) == ["cloudflare"])
        #expect(resolution.hosts[0].url == "https://api.cloudflare.com/client/v4/accounts/abc123/ai/run/typesafe/jev")
        #expect(resolution.hosts[0].format == .workersAI)
    }

    @Test func cloudflareThroughAIGateway() throws {
        let host = try HostPresets.host("cloudflare", environment: env([
            "CLOUDFLARE_API_TOKEN_JEV": "cf", "CLOUDFLARE_API_TOKEN": "other", "CLOUDFLARE_ACCOUNT_ID": "abc",
            "CLOUDFLARE_AI_GATEWAY": "my-gw",
        ])).get()
        #expect(host.url == "https://gateway.ai.cloudflare.com/v1/abc/my-gw/workers-ai/typesafe/jev")
        #expect(host.apiKey == "cf")
    }

    @Test func cloudflareRejectsPathTricks() {
        let result = HostPresets.host("cloudflare", environment: env(["CLOUDFLARE_API_TOKEN": "cf", "CLOUDFLARE_ACCOUNT_ID": "../x"]))
        #expect(throws: HostProblem.self) { try result.get() }
    }

    @Test func emptyValuesCountAsUnset() {
        let resolution = HostPresets.resolve(environment: env(["OPENROUTER_API_KEY": "  ", "AI_GATEWAY_API_KEY": "v"]))
        #expect(resolution.hosts.map(\.id) == ["vercel"])
    }

    @Test func flagBeatsEnvironmentAndBuildsAFailoverChain() {
        let values = ["DSHIFT_HOST": "vercel", "AI_GATEWAY_API_KEY": "v", "OPENROUTER_API_KEY": "or", "DSHIFT_API_KEY": "ts"]
        let resolution = HostPresets.resolve(flag: "openrouter, typesafe,openrouter", environment: env(values))
        #expect(resolution.hosts.map(\.id) == ["openrouter", "typesafe"])
        #expect(resolution.source == "--host")
        #expect(HostPresets.resolve(environment: env(values)).hosts.map(\.id) == ["vercel"])
    }

    @Test func namedHostsWithoutCredentialsAreProblems() {
        let resolution = HostPresets.resolve(environment: env(["DSHIFT_HOST": "cloudflare,bogus,openrouter", "OPENROUTER_API_KEY": "or"]))
        #expect(resolution.hosts.map(\.id) == ["openrouter"])
        #expect(resolution.problems.map(\.host) == ["cloudflare", "bogus"])
    }

    @Test func noneTurnsRoutingOff() {
        #expect(HostPresets.resolve(environment: env(["DSHIFT_HOST": "none", "OPENROUTER_API_KEY": "or"])).hosts.isEmpty)
        #expect(HostPresets.resolve(flag: "off", environment: env(["OPENROUTER_API_KEY": "or"])).hosts.isEmpty)
    }

    @Test(arguments: [
        ("https://jev.example.com/run", true),
        ("http://localhost:8080/jev", true),
        ("http://127.0.0.1:8080/jev", true),
        ("http://jev.example.com/run", false),
        ("ftp://jev.example.com", false),
        ("not a url", false),
    ])
    func customHostURLs(url: String, allowed: Bool) {
        let result = HostPresets.host("custom", environment: env(["DSHIFT_BASE_URL": url, "DSHIFT_HOST_API_KEY": "k"]))
        #expect(((try? result.get()) != nil) == allowed)
    }

    @Test func customTransportMustBeKnown() throws {
        let values = ["DSHIFT_BASE_URL": "https://x.test/jev", "DSHIFT_HOST_API_KEY": "k"]
        #expect(try HostPresets.host("custom", environment: env(values)).get().format == .systemOne)
        #expect(try HostPresets.host("custom", environment: env(values.merging(["DSHIFT_TRANSPORT": "vercel"]) { $1 })).get().format == .vercel)
        #expect(throws: HostProblem.self) {
            try HostPresets.host("custom", environment: env(values.merging(["DSHIFT_TRANSPORT": "grpc"]) { $1 })).get()
        }
    }

    @Test func problemsNeverQuoteSecrets() {
        let secret = "sk-very-secret"
        let values = ["CLOUDFLARE_API_TOKEN": secret, "CLOUDFLARE_ACCOUNT_ID": "bad/acct", "DSHIFT_HOST": "cloudflare"]
        let resolution = HostPresets.resolve(environment: env(values))
        #expect(!resolution.problems.isEmpty)
        #expect(!resolution.problems.contains { $0.description.contains(secret) })
    }
}
