import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import HummingbirdWSClient
import DownshiftCore
import Logging
import NIOConcurrencyHelpers
import NIOCore
import Testing
@testable import DownshiftProxy

/// What the fake Codex upstream saw, in order.
actor CodexUpstreamLog {
    struct Seen: Sendable {
        var path: String
        var authorization: String?
        var account: String?
        var body: JSONValue?
    }
    var seen: [Seen] = []
    func record(_ entry: Seen) { seen.append(entry) }
}

let codexCatalogBody = #"""
{"models":[{"slug":"gpt-5.6-terra","display_name":"GPT-5.6-Terra","visibility":"list","supported_in_api":true,"priority":2,"prefer_websockets":true},{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list","supported_in_api":true,"priority":3,"prefer_websockets":true}]}
"""#

let codexCreated = "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"r1\"}}\n\n"
let codexCompleted = "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\"}}\n\n"

/// Runs a fake ChatGPT backend (under `/backend-api/codex`) and public API (under `/v1`), and
/// the Codex route in front of them at `/codex`.
func withCodexProxy(
    engine: RoutingEngine,
    upstreamOverride: String? = nil,
    _ body: @Sendable (_ proxyPort: Int, _ client: HTTPClient, _ upstream: CodexUpstreamLog) async throws -> Void
) async throws {
    let log = CodexUpstreamLog()
    let router = Router()
    @Sendable func record(_ request: Request, _ path: String) async throws {
        let buffer = try await request.body.collect(upTo: 1 << 20)
        await log.record(.init(path: path, authorization: request.headers[.authorization],
                               account: request.headers[HTTPField.Name("chatgpt-account-id")!],
                               body: buffer.readableBytes > 0 ? try JSONValue.parse(buffer.readableBytesView) : nil))
    }
    router.get("/backend-api/codex/models") { request, _ -> Response in
        try await record(request, "/backend-api/codex/models")
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: codexCatalogBody)))
    }
    for path in ["/backend-api/codex/responses", "/v1/responses"] {
        router.post(RouterPath(stringLiteral: path)) { request, _ -> Response in
            try await record(request, path)
            // Two writes, so the first event arrives on its own.
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init { writer in
                try await writer.write(ByteBuffer(string: codexCreated))
                try await writer.write(ByteBuffer(string: codexCompleted))
                try await writer.finish(nil)
            })
        }
    }
    let upstream = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    let client = HTTPClient.jevUpstream()
    do {
        try await upstream.test(.live) { upstreamClient in
            let port = try #require(upstreamClient.port)
            let interceptor = CodexInterceptor(engine: engine, apiUpstream: "http://localhost:\(port)/v1")
            let route = PassthroughResponder.Route(prefix: "/codex",
                                                   upstream: upstreamOverride ?? "http://localhost:\(port)/backend-api/codex",
                                                   interceptor: interceptor)
            let responder = PassthroughResponder(client: client, routes: [route], dumper: nil, logger: Logger(label: "test"))
            let proxy = Application(responder: responder, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
            try await proxy.test(.live) { proxyClient in
                try await body(try #require(proxyClient.port), client, log)
            }
        }
    } catch {
        try await client.shutdown()
        throw error
    }
    try await client.shutdown()
}

func codexTurn(_ text: String, cacheKey: String? = "main", tools: Bool = true) -> String {
    let key = cacheKey.map { #""prompt_cache_key":"\#($0)","# } ?? ""
    let additional = tools ? #"{"type":"additional_tools","role":"developer","tools":[{}]},"# : ""
    return #"{"model":"downshift",\#(key)"reasoning":{"effort":"medium"},"input":[\#(additional){"role":"user","content":[{"type":"input_text","text":"\#(text)"}]}]}"#
}

let codexHeaders = [("authorization", "Bearer subscription-token"), ("chatgpt-account-id", "acct"), ("session-id", "cx1")]

func text(_ response: HTTPClientResponse) async throws -> String {
    String(buffer: try await response.body.collect(upTo: 1 << 20))
}

@Suite struct CodexProxyTests {
    static let answer = RouteAnswer(
        choice: "gpt-5.6-sol", confidence: 0.91,
        response: ["answers": ["model": ["choice": "gpt-5.6-sol", "confidence": .number(0.91)]]])

    @Test func preservesAuthExtendsThePickerRoutesAndShowsTheDecision() async throws {
        let spy = RouterSpy(Self.answer)
        let dir = try temporaryDirectory()
        let engine = RoutingEngine(adapter: CodexAdapter(), baseline: .balanced, available: Tier.allCases,
                                   router: spy.router, store: StatusStore(directory: dir))
        try await withCodexProxy(engine: engine) { port, client, upstream in
            var catalogRequest = HTTPClientRequest(url: "http://localhost:\(port)/codex/models?client_version=1")
            for (name, value) in codexHeaders { catalogRequest.headers.add(name: name, value: value) }
            let catalog = try JSONValue.parse(Array(try await text(try await client.execute(catalogRequest, timeout: .seconds(10))).utf8))
            let models = try #require(catalog["models"]?.arrayValue)
            #expect(models.map { $0["slug"]?.stringValue } == ["downshift", "gpt-5.6-terra", "gpt-5.6-sol"])
            #expect(models[0]["prefer_websockets"] == .bool(false))

            let stream = try await text(try await post(client, port: port, path: "/codex/responses",
                                                       codexTurn("debug this race"), headers: codexHeaders))
            let seen = await upstream.seen
            #expect(seen[0].authorization == "Bearer subscription-token")
            #expect(seen[0].account == "acct")
            #expect(seen[1].path == "/backend-api/codex/responses")
            #expect(seen[1].authorization == "Bearer subscription-token")
            #expect(seen[1].body?["model"]?.stringValue == "gpt-5.6-sol")
            #expect(spy.requests.first?.models.map(\.id) == ["gpt-5.6-terra", "gpt-5.6-sol"])
            #expect(spy.requests.first?.prompt == "debug this race")

            let status = try #require(StatusStore(directory: dir).read(session: "cx1"))
            #expect(status["tier"]?.stringValue == "strong")
            #expect(status["model"]?.stringValue == "gpt-5.6-sol")
            #expect(status["confidence"]?.doubleValue == 0.91)
            // Only what the status line shows: never the prompt or Jev's exchange.
            #expect(Set(status.keys) == ["tier", "model", "confidence", "reason", "at"])

            let created = try #require(stream.range(of: "response.created"))
            let decision = try #require(stream.range(of: "[Jev] routed this turn to gpt-5.6-sol"))
            let completed = try #require(stream.range(of: "response.completed"))
            #expect((created.upperBound < decision.lowerBound) && (decision.upperBound < completed.lowerBound))
            #expect(stream.hasPrefix(codexCreated))
            #expect(stream.hasSuffix(codexCompleted))

            // The app's title call is not a turn: no routing, no new decision.
            let title = #"{"model":"downshift","input":[{"type":"additional_tools","role":"developer","tools":[{}]},{"role":"user","content":"Generate a concise, single-line task title of at most 36 characters"},{"role":"user","content":"<environment_context><timezone>Asia/Calcutta</timezone></environment_context>"}]}"#
            let titleStream = try await text(try await post(client, port: port, path: "/codex/responses", title, headers: codexHeaders))
            #expect(!titleStream.contains("[Jev]"))
            #expect(spy.requests.count == 1)
            let afterTitle = try #require(StatusStore(directory: dir).read(session: "cx1"))
            #expect(afterTitle["confidence"]?.doubleValue == 0.91)
        }
    }

    /// A tool-result continuation is the same turn: it keeps the routed model and doesn't ask Jev.
    @Test func followUpsReuseTheRoutedModel() async throws {
        let spy = RouterSpy(Self.answer)
        let engine = RoutingEngine(adapter: CodexAdapter(), baseline: .balanced, available: Tier.allCases,
                                   router: spy.router, store: nil)
        try await withCodexProxy(engine: engine) { port, client, upstream in
            var catalogRequest = HTTPClientRequest(url: "http://localhost:\(port)/codex/models?client_version=1")
            for (name, value) in codexHeaders { catalogRequest.headers.add(name: name, value: value) }
            _ = try await text(try await client.execute(catalogRequest, timeout: .seconds(10)))
            _ = try await text(try await post(client, port: port, path: "/codex/responses",
                                              codexTurn("debug this race"), headers: codexHeaders))
            let followUp = #"{"model":"downshift","prompt_cache_key":"main","reasoning":{"effort":"medium"},"input":[{"type":"additional_tools","role":"developer","tools":[{}]},{"role":"user","content":[{"type":"input_text","text":"debug this race"}]},{"type":"function_call","call_id":"1","name":"shell","arguments":"{}"},{"type":"function_call_output","call_id":"1","output":"done"}]}"#
            _ = try await text(try await post(client, port: port, path: "/codex/responses", followUp, headers: codexHeaders))
            #expect(spy.requests.count == 1)
            let seen = await upstream.seen
            #expect(seen.count == 3)
            #expect(seen.last?.body?["model"]?.stringValue == "gpt-5.6-sol")
        }
    }

    @Test func apiKeyRequestsGoToThePublicAPI() async throws {
        let engine = RoutingEngine(adapter: CodexAdapter(), baseline: .balanced, available: Tier.allCases,
                                   router: RouterSpy(Self.answer).router, store: nil)
        try await withCodexProxy(engine: engine) { port, client, upstream in
            let stream = try await text(try await post(client, port: port, path: "/codex/responses", codexTurn("hello"),
                                                       headers: [("authorization", "Bearer sk-test")]))
            let seen = await upstream.seen
            #expect(seen.map(\.path) == ["/v1/responses"])
            #expect(seen[0].authorization == "Bearer sk-test")
            #expect(stream.contains("[Jev] routed this turn"))
        }
    }

    @Test func aModelThePickerChoseIsLeftAlone() async throws {
        let spy = RouterSpy(Self.answer)
        let dir = try temporaryDirectory()
        let engine = RoutingEngine(adapter: CodexAdapter(), baseline: .balanced, available: Tier.allCases,
                                   router: spy.router, store: StatusStore(directory: dir))
        try await withCodexProxy(engine: engine) { port, client, upstream in
            let json = codexTurn("hi").replacingOccurrences(of: "downshift", with: "gpt-5.6-terra")
            let stream = try await text(try await post(client, port: port, path: "/codex/responses", json, headers: codexHeaders))
            #expect(stream == codexCreated + codexCompleted)
            #expect(await upstream.seen[0].body?["model"]?.stringValue == "gpt-5.6-terra")
            #expect(spy.requests.isEmpty)
            #expect(StatusStore(directory: dir).read(session: "cx1")?["manual"] == .bool(true))
        }
    }

    @Test func startsOnTheConfiguredCodexModel() async throws {
        let engine = RoutingEngine(adapter: CodexAdapter(), baseline: .strong, baselineModel: "gpt-5.6-sol",
                                   available: Tier.allCases, router: nil, store: nil)
        try await withCodexProxy(engine: engine) { port, client, upstream in
            var catalogRequest = HTTPClientRequest(url: "http://localhost:\(port)/codex/models")
            catalogRequest.headers.add(name: "chatgpt-account-id", value: "acct")
            _ = try await client.execute(catalogRequest, timeout: .seconds(10))
            let stream = try await text(try await post(client, port: port, path: "/codex/responses",
                                                       codexTurn("hello"), headers: codexHeaders))
            #expect(await upstream.seen[1].body?["model"]?.stringValue == "gpt-5.6-sol")
            #expect(stream.contains("[Jev] unavailable; using gpt-5.6-sol."))
        }
    }

    @Test func unreachableUpstreamIsAnOpenAIError() async throws {
        let engine = RoutingEngine(adapter: CodexAdapter(), baseline: .balanced, available: Tier.allCases, router: nil, store: nil)
        try await withCodexProxy(engine: engine, upstreamOverride: "http://127.0.0.1:1") { port, client, _ in
            let response = try await post(client, port: port, path: "/codex/responses", codexTurn("hi"), headers: codexHeaders)
            #expect(response.status == .badGateway)
            let json = try JSONValue.parse(Array(try await text(response).utf8))
            #expect(json["error"]?["type"]?.stringValue == "proxy_error")
            #expect(json["error"]?["message"]?.stringValue?.isEmpty == false)
        }
    }
}

/// The WebSocket fallback: a `response.create` for the sentinel is routed, and the decision
/// follows the upstream's first reply.
@Suite struct CodexWebSocketTests {
    @Test func responseCreateIsRoutedAndTheDecisionFollowsTheFirstReply() async throws {
        let received = NIOLockedValueBox<[String]>([])
        let router = Router()
        let upstream = Application(
            router: router,
            server: .http1WebSocketUpgrade(configuration: .init(ws: .init(maxFrameSize: 1 << 22))) { _, _, _ in
                .upgrade([:]) { inbound, outbound, _ in
                    for try await message in inbound.messages(maxSize: 1 << 22) {
                        guard case .text(let text) = message else { continue }
                        received.withLockedValue { $0.append(text) }
                        try await outbound.write(.text(#"{"type":"response.created"}"#))
                        try await outbound.write(.text(#"{"type":"response.completed"}"#))
                    }
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        let client = HTTPClient.jevUpstream()
        let spy = RouterSpy(CodexProxyTests.answer)
        let engine = RoutingEngine(adapter: CodexAdapter(), baseline: .balanced, available: Tier.allCases,
                                   router: spy.router, store: nil)
        do {
            try await upstream.test(.live) { upstreamClient in
                let port = try #require(upstreamClient.port)
                let configuration = ProxyServer.Configuration(port: 0, upstream: "http://127.0.0.1:1",
                                                              codexUpstream: "http://localhost:\(port)", codexEngine: engine)
                let proxy = ProxyServer.makeApplication(configuration, client: client, dumper: nil, logger: Logger(label: "test"))
                try await proxy.test(.live) { proxyClient in
                    let proxyPort = try #require(proxyClient.port)
                    let replies = NIOLockedValueBox<[String]>([])
                    var headers = HTTPFields()
                    headers[HTTPField.Name("session-id")!] = "ws1"
                    try await WebSocketClient.connect(url: "ws://localhost:\(proxyPort)/codex/responses",
                                                      configuration: .init(maxFrameSize: 1 << 22, additionalHeaders: headers),
                                                      logger: Logger(label: "test-client")) { inbound, outbound, _ in
                        let create = #"{"type":"response.create","model":"downshift","input":[{"type":"additional_tools","role":"developer","tools":[{}]},{"role":"user","content":[{"type":"input_text","text":"debug this race"}]}]}"#
                        try await outbound.write(.text(create))
                        for try await message in inbound.messages(maxSize: 1 << 22) {
                            guard case .text(let text) = message else { continue }
                            let count = replies.withLockedValue { $0.append(text); return $0.count }
                            if count == 5 { break }
                        }
                        try await outbound.close(.normalClosure, reason: nil)
                    }
                    let sent = try JSONValue.parse(try #require(received.withLockedValue { $0.first }))
                    #expect(sent["model"]?.stringValue == "gpt-5.6-sol")
                    #expect(sent["type"]?.stringValue == "response.create")
                    let types = replies.withLockedValue { $0 }.map { try? JSONValue.parse($0)["type"]?.stringValue }
                    #expect(types == ["response.created", "response.output_item.added", "response.output_text.delta",
                                      "response.output_item.done", "response.completed"])
                    #expect(spy.requests.count == 1)
                }
            }
        } catch {
            try await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }

    /// Each `response.create` is metered when the upstream's message ending it arrives, routed
    /// or not; reply text that merely mentions an end event is not mistaken for one.
    @Test func webSocketTurnsAreRecordedInTheLedger() async throws {
        let router = Router()
        let upstream = Application(
            router: router,
            server: .http1WebSocketUpgrade(configuration: .init(ws: .init(maxFrameSize: 1 << 22))) { _, _, _ in
                .upgrade([:]) { inbound, outbound, _ in
                    for try await message in inbound.messages(maxSize: 1 << 22) {
                        guard case .text(let text) = message, let json = try? JSONValue.parse(text),
                              json["type"]?.stringValue == "response.create" else { continue }
                        let model = json["model"]?.stringValue ?? "?"
                        try await outbound.write(.text(#"{"type":"response.created","response":{"id":"r1"}}"#))
                        try await outbound.write(.text(#"{"type":"response.output_text.delta","delta":"say \"completed\" or \"error\""}"#))
                        try await outbound.write(.text(#"{"type":"response.completed","response":{"id":"r1","model":"\#(model)","usage":{"input_tokens":1000,"input_tokens_details":{"cached_tokens":600},"output_tokens":50}}}"#))
                    }
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        let client = HTTPClient.jevUpstream()
        let ledger = UsageLedger(directory: try temporaryDirectory().appendingPathComponent("usage"))
        let engine = RoutingEngine(adapter: CodexAdapter(), baseline: .balanced, available: Tier.allCases,
                                   router: RouterSpy(CodexProxyTests.answer).router, store: nil, ledger: ledger)
        do {
            try await upstream.test(.live) { upstreamClient in
                let port = try #require(upstreamClient.port)
                let configuration = ProxyServer.Configuration(port: 0, upstream: "http://127.0.0.1:1",
                                                              codexUpstream: "http://localhost:\(port)", codexEngine: engine)
                let proxy = ProxyServer.makeApplication(configuration, client: client, dumper: nil, logger: Logger(label: "test"))
                try await proxy.test(.live) { proxyClient in
                    let proxyPort = try #require(proxyClient.port)
                    var headers = HTTPFields()
                    headers[HTTPField.Name("session-id")!] = "ws1"
                    try await WebSocketClient.connect(url: "ws://localhost:\(proxyPort)/codex/responses",
                                                      configuration: .init(maxFrameSize: 1 << 22, additionalHeaders: headers),
                                                      logger: Logger(label: "test-client")) { inbound, outbound, _ in
                        func create(_ model: String) -> String {
                            #"{"type":"response.create","model":"\#(model)","input":[{"type":"additional_tools","role":"developer","tools":[{}]},{"role":"user","content":[{"type":"input_text","text":"debug this race"}]}]}"#
                        }
                        try await outbound.write(.text(create("downshift")))
                        var completed = 0
                        for try await message in inbound.messages(maxSize: 1 << 22) {
                            guard case .text(let text) = message, text.contains(#""type":"response.completed""#) else { continue }
                            completed += 1
                            if completed == 1 { try await outbound.write(.text(create("gpt-5.6-terra"))) } else { break }
                        }
                        try await outbound.close(.normalClosure, reason: nil)
                    }
                    let records = try await waitForRecords(ledger, count: 2)
                    let tokens = TokenUsage(input: 400, cacheRead: 600, output: 50)
                    #expect(records.count == 2)
                    #expect(records.first == UsageRecord(at: records[0].at, kind: .turn, app: "codex", session: "ws1", model: "gpt-5.6-sol",
                                                          baseline: CodexAdapter().model(for: .balanced, in: []), routed: true, tokens: tokens))
                    #expect(records.last == UsageRecord(at: records[1].at, kind: .turn, app: "codex", session: "ws1", model: "gpt-5.6-terra",
                                                         baseline: nil, routed: false, tokens: tokens))
                }
            }
        } catch {
            try await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }
}
