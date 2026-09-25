import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import JevCore
import Logging
import NIOCore
import ServiceLifecycle
import Testing
@testable import JevProxy

/// What the fake Anthropic upstream saw.
actor RecordedUpstream {
    var bodies: [String: [JSONValue]] = [:]
    var modelsAcceptEncoding: [String] = []
    func record(_ path: String, _ body: JSONValue) { bodies[path, default: []].append(body) }
    func acceptEncoding(_ values: [String]) { modelsAcceptEncoding = values }
    func last(_ path: String) -> JSONValue? { bodies[path]?.last }
}

/// Counts router calls and returns a fixed answer.
final class RouterSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RouteRequest] = []
    let answer: RouteAnswer?
    init(_ answer: RouteAnswer?) { self.answer = answer }
    var requests: [RouteRequest] { lock.withLock { _requests } }
    var router: JevRouter {
        { [self] request in
            lock.withLock { _requests.append(request) }
            return answer
        }
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("jev-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let catalogBody = #"""
{"data":[{"id":"claude-opus-5","display_name":"Claude Opus 5","created_at":"2026-05-01T00:00:00Z","type":"model"},{"id":"claude-opus-4-8","display_name":"Claude Opus 4.8","created_at":"2026-02-01T00:00:00Z","type":"model"},{"id":"claude-sonnet-5","display_name":"Claude Sonnet 5","created_at":"2026-04-01T00:00:00Z","type":"model"},{"id":"gpt-image-1","type":"model"}],"has_more":false}
"""#

/// Runs a fake Anthropic upstream and the Claude proxy in front of it.
func withClaudeProxy(
    engine: RoutingEngine,
    _ body: @Sendable (_ proxyPort: Int, _ client: HTTPClient, _ upstream: RecordedUpstream) async throws -> Void
) async throws {
    let recorded = RecordedUpstream()
    let router = Router()
    router.get("/v1/models") { request, _ -> Response in
        await recorded.acceptEncoding(request.headers[values: .acceptEncoding])
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: catalogBody)))
    }
    for path in ["/v1/messages", "/v1/messages/count_tokens"] {
        router.post(RouterPath(stringLiteral: path)) { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            await recorded.record(path, try JSONValue.parse(buffer.readableBytesView))
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: "{}")))
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
            try await proxy.test(.live) { proxyClient in
                try await body(try #require(proxyClient.port), client, recorded)
            }
        }
    } catch {
        try await client.shutdown()
        throw error
    }
    try await client.shutdown()
}

func post(_ client: HTTPClient, port: Int, path: String = "/v1/messages", _ json: String,
          headers: [(String, String)] = []) async throws -> HTTPClientResponse {
    var request = HTTPClientRequest(url: "http://localhost:\(port)\(path)")
    request.method = .POST
    request.headers.add(name: "content-type", value: "application/json")
    for (name, value) in headers { request.headers.add(name: name, value: value) }
    request.body = .bytes(ByteBuffer(string: json))
    return try await client.execute(request, timeout: .seconds(10))
}

func turn(_ text: String, session: String? = nil, model: String = "jev-router") -> String {
    let metadata = session.map { #","metadata":{"user_id":"{\"session_id\":\"\#($0)\"}"}"# } ?? ""
    return #"{"model":"\#(model)","max_tokens":10,"tools":[{"name":"t","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"\#(text)"}]\#(metadata)}"#
}

@Suite struct ClaudeProxyTests {
    @Test func routesToTheExactAccountModelJevChose() async throws {
        let spy = RouterSpy(RouteAnswer(choice: "claude-opus-4-8", confidence: 0.91))
        let dir = try temporaryDirectory()
        let engine = RoutingEngine(baseline: .strong, available: Tier.allCases, router: spy.router, store: StatusStore(directory: dir))
        try await withClaudeProxy(engine: engine) { port, client, upstream in
            var catalog = HTTPClientRequest(url: "http://localhost:\(port)/v1/models")
            catalog.headers.add(name: "accept-encoding", value: "gzip, br")
            let response = try await client.execute(catalog, timeout: .seconds(10))
            let body = try await response.body.collect(upTo: 1 << 20)
            // The catalog passes through byte for byte, and uncompressed so it can be read.
            #expect(String(buffer: body) == catalogBody)
            #expect(await upstream.modelsAcceptEncoding.isEmpty)

            _ = try await post(client, port: port, turn("design the storage layer", session: "s1"))
            #expect(spy.requests.first?.models.map(\.id) == ["claude-opus-5", "claude-opus-4-8", "claude-sonnet-5"])
            #expect(await upstream.last("/v1/messages")?["model"]?.stringValue == "claude-opus-4-8")
            let status = try #require(StatusStore(directory: dir).read(session: "s1"))
            #expect(status["model"]?.stringValue == "claude-opus-4-8")
        }
    }

    @Test func noMetadataIsRecordedUnderTheConversationKey() async throws {
        let spy = RouterSpy(RouteAnswer(choice: "claude-sonnet-5", confidence: 0.77))
        let dir = try temporaryDirectory()
        let engine = RoutingEngine(baseline: .balanced, available: Tier.allCases, router: spy.router, store: StatusStore(directory: dir))
        try await withClaudeProxy(engine: engine) { port, client, _ in
            let json = turn("hello there")
            _ = try await post(client, port: port, json)
            let key = ClaudeAdapter.conversationKey(try JSONValue.parse(json))
            let status = try #require(StatusStore(directory: dir).read(session: key))
            #expect(status["tier"]?.stringValue == "balanced")
            #expect(status["confidence"]?.doubleValue == 0.77)
        }
    }

    @Test func theSessionHeaderIsUsedWithoutMetadata() async throws {
        let spy = RouterSpy(RouteAnswer(choice: "claude-sonnet-5", confidence: 0.9))
        let dir = try temporaryDirectory()
        let engine = RoutingEngine(baseline: .balanced, available: Tier.allCases, router: spy.router, store: StatusStore(directory: dir))
        try await withClaudeProxy(engine: engine) { port, client, _ in
            _ = try await post(client, port: port, turn("hi"), headers: [(ClaudeAdapter.sessionHeader, "desktop-7")])
            #expect(StatusStore(directory: dir).read(session: "desktop-7")?["tier"]?.stringValue == "balanced")
        }
    }

    @Test func aManualModelPassesThroughAndOnlyAgentTurnsFlipToManual() async throws {
        let spy = RouterSpy(nil)
        let dir = try temporaryDirectory()
        let store = StatusStore(directory: dir)
        let engine = RoutingEngine(baseline: .balanced, available: Tier.allCases, router: spy.router, store: store)
        try await withClaudeProxy(engine: engine) { port, client, upstream in
            let auxiliary = #"{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"title"}],"metadata":{"user_id":"{\"session_id\":\"m1\"}"}}"#
            _ = try await post(client, port: port, auxiliary)
            #expect(store.read(session: "m1") == nil)

            _ = try await post(client, port: port, turn("do it", session: "m1", model: "claude-opus-5"))
            #expect(store.read(session: "m1")?["manual"] == .bool(true))
            #expect(await upstream.last("/v1/messages")?["model"]?.stringValue == "claude-opus-5")
            #expect(spy.requests.isEmpty)
        }
    }

    @Test func withoutJevTheBaselineIsUsedAndFollowUpsReuseTheTier() async throws {
        let engine = RoutingEngine(baseline: .fast, available: Tier.allCases, router: nil, store: nil)
        try await withClaudeProxy(engine: engine) { port, client, upstream in
            _ = try await post(client, port: port, turn("hi", session: "b1"))
            let first = try #require(await upstream.last("/v1/messages"))
            #expect(first["model"]?.stringValue == "claude-haiku-4-5-20251001")

            let followUp = #"{"model":"jev-router","thinking":{"type":"adaptive"},"tools":[{"name":"t","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"t","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}],"metadata":{"user_id":"{\"session_id\":\"b1\"}"}}"#
            _ = try await post(client, port: port, followUp)
            let second = try #require(await upstream.last("/v1/messages"))
            #expect(second["model"]?.stringValue == "claude-haiku-4-5-20251001")
            #expect(second["thinking"] == nil)
            #expect(await engine.conversationCount == 1)
        }
    }

    @Test func countTokensIsRewrittenWithoutAskingJev() async throws {
        let spy = RouterSpy(RouteAnswer(choice: "claude-opus-5", confidence: 0.99))
        let engine = RoutingEngine(baseline: .balanced, available: Tier.allCases, router: spy.router, store: nil)
        try await withClaudeProxy(engine: engine) { port, client, upstream in
            _ = try await post(client, port: port, path: "/v1/messages/count_tokens", turn("count me", session: "c1"))
            #expect(await upstream.last("/v1/messages/count_tokens")?["model"]?.stringValue == "claude-sonnet-5")
            #expect(spy.requests.isEmpty)
        }
    }

    @Test func explainRequestsAreNotRoutedOrRecorded() async throws {
        let spy = RouterSpy(RouteAnswer(choice: "claude-opus-5", confidence: 0.99))
        let dir = try temporaryDirectory()
        let engine = RoutingEngine(baseline: .balanced, available: Tier.allCases, router: spy.router, store: StatusStore(directory: dir))
        try await withClaudeProxy(engine: engine) { port, client, upstream in
            _ = try await post(client, port: port, turn("<jev-explain>why</jev-explain>", session: "e1"))
            #expect(spy.requests.isEmpty)
            #expect(StatusStore(directory: dir).read(session: "e1") == nil)
            #expect(await upstream.last("/v1/messages")?["model"]?.stringValue == "claude-sonnet-5")
        }
    }

    @Test func conversationsAreCappedLeastRecentlyUsedFirst() async throws {
        let engine = RoutingEngine(baseline: .balanced, available: Tier.allCases, router: nil, store: nil)
        for i in 0..<(RoutingEngine.conversationLimit + 5) {
            var body = try JSONValue.parse(turn("conversation \(i)"))
            await engine.process(&body)
        }
        #expect(await engine.conversationCount == RoutingEngine.conversationLimit)
    }

    @Test func headIsAnsweredLocallyAndUnreachableUpstreamIsJSON() async throws {
        let client = HTTPClient.jevUpstream(connectTimeout: .milliseconds(300))
        let engine = RoutingEngine(baseline: .balanced, available: Tier.allCases, router: nil, store: nil)
        let responder = PassthroughResponder(
            client: client,
            routes: [PassthroughResponder.Route(prefix: "", upstream: "http://127.0.0.1:1", interceptor: ClaudeInterceptor(engine: engine))],
            dumper: nil, logger: Logger(label: "test"))
        let proxy = Application(responder: responder, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await proxy.test(.router) { testClient in
            try await testClient.execute(uri: "/", method: .head) { response in
                #expect(response.status == .ok)
            }
            try await testClient.execute(uri: "/v1/messages", method: .post, body: ByteBuffer(string: turn("hi"))) { response in
                #expect(response.status == .badGateway)
                #expect(response.headers[.contentType] == "application/json")
                let json = try JSONValue.parse(response.body.readableBytesView)
                #expect(json["type"]?.stringValue == "error")
                #expect(json["error"]?["type"]?.stringValue == "api_error")
            }
        }
        try await client.shutdown()
    }
}

/// Plan §5b: cleanup stops only after the proxy has drained, and a stream that outlives the
/// grace period is cancelled.
@Suite struct LifecycleOrderTests {
    actor Timeline {
        var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    struct CleanupService: Service {
        let timeline: Timeline
        func run() async throws {
            try? await gracefulShutdown()
            await timeline.add("cleanup")
        }
    }

    func runStream(chunks: Int, grace: Duration) async throws -> (received: String, events: [String]) {
        let probe = UpstreamProbe()
        let timeline = Timeline()
        let result = LockedBox<String>("")
        try await withProxiedUpstream(chunks: chunks, interval: .milliseconds(60), probe: probe) { upstreamPort, client in
            let (portStream, portContinuation) = AsyncStream.makeStream(of: Int.self)
            let proxy = Application(
                responder: PassthroughResponder(client: client, upstream: "http://localhost:\(upstreamPort)",
                                                dumper: nil, logger: Logger(label: "test")),
                configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                onServerRunning: { portContinuation.yield($0.localAddress?.port ?? 0) })
            let group = ProxyServer.serviceGroup(proxy: proxy, cleanup: CleanupService(timeline: timeline),
                                                 grace: grace, signals: [], logger: Logger(label: "test"))
            async let run: Void = group.run()
            var ports = portStream.makeAsyncIterator()
            let port = try #require(await ports.next())

            var request = HTTPClientRequest(url: "http://localhost:\(port)/v1/messages")
            request.method = .POST
            request.body = .bytes(ByteBuffer(string: "{}"))
            let response = try await client.execute(request, timeout: .seconds(10))
            var received = ""
            var iterator = response.body.makeAsyncIterator()
            received += String(buffer: try #require(await iterator.next()))
            await group.triggerGracefulShutdown()
            do {
                while let chunk = try await iterator.next() { received += String(buffer: chunk) }
            } catch {}
            await timeline.add("stream-end")
            try? await run
            result.value = received
        }
        return (result.value, await timeline.events)
    }

    @Test func cleanupRunsAfterTheInFlightStreamFinishes() async throws {
        let (received, events) = try await runStream(chunks: 5, grace: .seconds(10))
        #expect(received.hasSuffix((0..<5).map { "data: \($0)\n\n" }.joined()))
        #expect(events == ["stream-end", "cleanup"])
    }

    @Test func aStreamLongerThanTheGraceIsCancelled() async throws {
        let start = ContinuousClock.now
        let (received, _) = try await runStream(chunks: 100, grace: .milliseconds(300))
        #expect(!received.contains("data: 99\n\n"))
        #expect(ContinuousClock.now - start < .seconds(4))
    }
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
