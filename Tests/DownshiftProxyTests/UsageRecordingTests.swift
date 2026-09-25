import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import DownshiftCore
import Logging
import NIOCore
import Testing
@testable import DownshiftProxy

/// Runs a fake Messages API that streams usage for whichever model it was asked for, and the
/// Claude proxy in front of it. `claude-opus-5` replies are marked gzip, so they can't be metered.
func withMeteredClaudeProxy(engine: RoutingEngine,
                            _ body: @Sendable (_ port: Int, _ client: HTTPClient) async throws -> Void) async throws {
    let router = Router()
    for path in ["/v1/messages", "/v1/messages/count_tokens"] {
        router.post(RouterPath(stringLiteral: path)) { request, _ -> Response in
            let json = try JSONValue.parse(try await request.body.collect(upTo: 1 << 20).readableBytesView)
            let model = json["model"]?.stringValue ?? ""
            guard path == "/v1/messages" else {
                return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: #"{"input_tokens":5}"#)))
            }
            let sse = """
            event: message_start
            data: {"type":"message_start","message":{"model":"\(model)","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":2000,"output_tokens":1}}}

            event: message_delta
            data: {"type":"message_delta","usage":{"output_tokens":50}}


            """
            var headers: HTTPFields = [.contentType: "text/event-stream"]
            if model == "claude-opus-5" { headers[.contentEncoding] = "gzip" }
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: sse)))
        }
    }
    let upstream = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    let client = HTTPClient.jevUpstream()
    do {
        try await upstream.test(.live) { upstreamClient in
            let port = try #require(upstreamClient.port)
            let responder = PassthroughResponder(
                client: client,
                routes: [PassthroughResponder.Route(prefix: "", upstream: "http://localhost:\(port)", interceptor: ClaudeInterceptor(engine: engine))],
                dumper: nil, logger: Logger(label: "test"))
            let proxy = Application(responder: responder, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
            try await proxy.test(.live) { proxyClient in try await body(try #require(proxyClient.port), client) }
        }
    } catch {
        try await client.shutdown()
        throw error
    }
    try await client.shutdown()
}

/// Posts and reads the whole reply, as the app would.
func exchange(_ client: HTTPClient, port: Int, path: String = "/v1/messages", _ json: String) async throws {
    let response = try await post(client, port: port, path: path, json)
    _ = try await response.body.collect(upTo: 1 << 20)
}

/// The ledger is written as the response body ends, which can be just after the client has it.
func waitForRecords(_ ledger: UsageLedger, count: Int) async throws -> [UsageRecord] {
    for _ in 0..<100 {
        let records = ledger.records()
        if records.count >= count { return records }
        try await Task.sleep(for: .milliseconds(20))
    }
    return ledger.records()
}

@Suite struct UsageRecordingTests {
    func ledger() throws -> UsageLedger { UsageLedger(directory: try temporaryDirectory().appendingPathComponent("usage")) }

    @Test func aRoutedTurnRecordsItsTokensAgainstTheBaselineAndJevsOwn() async throws {
        let ledger = try ledger()
        let jev: JSONValue = ["model": "jev-small", "usage": ["input_tokens": 700, "output_tokens": 20]]
        let spy = RouterSpy(RouteAnswer(choice: "claude-sonnet-5", confidence: 0.9, response: jev))
        let engine = RoutingEngine(baseline: .strong, available: Tier.allCases, router: spy.router, store: nil, ledger: ledger)
        try await withMeteredClaudeProxy(engine: engine) { port, client in
            try await exchange(client, port: port, turn("rename this variable", session: "u1"))
        }
        let records = try await waitForRecords(ledger, count: 2)
        let jevRecord = try #require(records.first { $0.kind == .jev })
        #expect(jevRecord.model == "jev-small")
        #expect(jevRecord.tokens == TokenUsage(input: 700, output: 20))
        #expect(jevRecord.session == "u1")

        let turnRecord = try #require(records.first { $0.kind == .turn })
        #expect(turnRecord.app == "claude")
        #expect(turnRecord.session == "u1")
        #expect(turnRecord.model == "claude-sonnet-5")
        // The baseline is what the conversation would have run on: the strong tier's model.
        #expect(turnRecord.baseline == ClaudeCLI().model(for: .strong, in: []))
        #expect(turnRecord.baseline != "claude-sonnet-5")
        #expect(turnRecord.routed)
        #expect(turnRecord.tokens == TokenUsage(input: 100, cacheWrite: 0, cacheRead: 2000, output: 50))

        // Token counts and model ids only: the prompt never reaches the ledger.
        let files = try FileManager.default.contentsOfDirectory(at: ledger.directory, includingPropertiesForKeys: nil)
        for file in files { #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("rename")) }
    }

    @Test func aManualTurnIsRecordedWithoutABaseline() async throws {
        let ledger = try ledger()
        let engine = RoutingEngine(baseline: .balanced, available: Tier.allCases, router: nil, store: nil, ledger: ledger)
        try await withMeteredClaudeProxy(engine: engine) { port, client in
            try await exchange(client, port: port, turn("do it", session: "u2", model: "claude-haiku-4-5-20251001"))
        }
        let records = try await waitForRecords(ledger, count: 1)
        #expect(records.count == 1)
        #expect(records.first?.routed == false)
        #expect(records.first?.baseline == nil)
        #expect(records.first?.model == "claude-haiku-4-5-20251001")
    }

    @Test func tokenCountingAndCompressedRepliesAreNotRecorded() async throws {
        let ledger = try ledger()
        let engine = RoutingEngine(baseline: .balanced, available: Tier.allCases, router: nil, store: nil, ledger: ledger)
        try await withMeteredClaudeProxy(engine: engine) { port, client in
            try await exchange(client, port: port, path: "/v1/messages/count_tokens", turn("count", session: "u3"))
            try await exchange(client, port: port, turn("compressed", session: "u3", model: "claude-opus-5"))
            // A metered reply after both, so waiting for it proves the others were skipped.
            try await exchange(client, port: port, turn("plain", session: "u3", model: "claude-sonnet-5"))
        }
        let records = try await waitForRecords(ledger, count: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ledger.records().map(\.model) == ["claude-sonnet-5"])
        #expect(records.count == 1)
    }
}
