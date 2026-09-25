import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import DownshiftCore
import NIOCore
import Testing
@testable import JevHosts

/// A scripted Jev host. Each path replays its steps in order and then repeats the last one.
actor FakeJev {
    struct Step: Sendable {
        var status: HTTPResponse.Status = .ok
        var body: String
        var delay: Duration = .zero
        var location: String?
    }

    var scripts: [String: [Step]]
    private(set) var calls: [String: Int] = [:]
    private(set) var authorizations: [String] = []
    private(set) var bodies: [JSONValue] = []

    init(_ scripts: [String: [Step]]) { self.scripts = scripts }

    func next(_ path: String, authorization: String?, body: JSONValue?) -> Step {
        let count = calls[path, default: 0]
        calls[path] = count + 1
        authorizations.append(authorization ?? "")
        if let body { bodies.append(body) }
        let steps = scripts[path] ?? []
        return steps.isEmpty ? Step(status: .notFound, body: "{}") : steps[min(count, steps.count - 1)]
    }

    func calls(_ path: String) -> Int { calls[path, default: 0] }
}

/// Runs the fake on an ephemeral port and hands the test a URL builder and an HTTP client.
func withFakeJev(
    _ fake: FakeJev,
    _ body: @Sendable (_ url: @Sendable (String) -> String, _ http: HTTPClient) async throws -> Void
) async throws {
    let router = Router()
    for path in await fake.scripts.keys {
        router.post(RouterPath(path)) { request, _ -> Response in
            let bytes = try await request.body.collect(upTo: 1 << 20)
            let step = await fake.next(path, authorization: request.headers[.authorization],
                                       body: try? JSONValue.parse(bytes.readableBytesView))
            if step.delay > .zero { try? await Task.sleep(for: step.delay) }
            var headers: HTTPFields = [.contentType: "application/json"]
            if let location = step.location { headers[.location] = location }
            return Response(status: step.status, headers: headers,
                            body: ResponseBody(byteBuffer: ByteBuffer(string: step.body)))
        }
    }
    let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
        try await app.test(.live) { client in
            let port = try #require(client.port)
            try await body({ "http://localhost:\(port)/\($0)" }, http)
        }
    } catch {
        try await http.shutdown()
        throw error
    }
    try await http.shutdown()
}

@Suite struct JevClientTests {
    static let fast = JevClient.Timing(attemptTimeout: .milliseconds(800), retries: 1, backoffInitial: .milliseconds(10),
                                       backoffMax: .milliseconds(20), deadline: .seconds(2))

    func host(_ id: String, _ url: String, format: JevHost.WireFormat = .systemOne) -> JevHost {
        JevHost(id: id, format: format, url: url, apiKey: "key-\(id)", model: "jev-latest")
    }

    @Test func answersAndSendsTheCredential() async throws {
        let fake = FakeJev(["a": [.init(body: Fixture.reply())]])
        try await withFakeJev(fake) { url, http in
            let client = JevClient(hosts: [host("a", url("a"))], http: http, timing: Self.fast)
            let outcome = await client.ask(try Fixture.request())
            #expect(outcome.result?.answers["model"]?.choice == "claude-b")
            #expect(outcome.host == "a" && outcome.failure == nil)
            #expect(outcome.attempts.map(\.reason) == ["ok"])
            #expect(await fake.authorizations == ["Bearer key-a"])
            #expect(await fake.bodies.first?["model"] == .string("jev-latest"))
            #expect(outcome.attempts.first?.reply == nil, "replies are only kept when asked")
        }
    }

    @Test func serverErrorsAreRetried() async throws {
        let fake = FakeJev(["a": [.init(status: .internalServerError, body: #"{"error":{"message":"boom"}}"#),
                                  .init(body: Fixture.reply())]])
        try await withFakeJev(fake) { url, http in
            let outcome = await JevClient(hosts: [host("a", url("a"))], http: http, timing: Self.fast).ask(try Fixture.request())
            #expect(outcome.result != nil)
            #expect(outcome.attempts.map(\.reason) == ["http-500", "ok"])
            #expect(outcome.attempts.first?.message == "boom")
        }
    }

    @Test func authFailuresMoveStraightToTheNextHost() async throws {
        let fake = FakeJev(["a": [.init(status: .unauthorized, body: #"{"errors":[{"message":"bad token"}]}"#)],
                            "b": [.init(body: #"{"result":\#(Fixture.reply(choice: "claude-a")),"success":true}"#)]])
        try await withFakeJev(fake) { url, http in
            let client = JevClient(hosts: [host("a", url("a")), host("b", url("b"), format: .workersAI)], http: http, timing: Self.fast)
            let outcome = await client.ask(try Fixture.request())
            #expect(await fake.calls("a") == 1)
            #expect(outcome.host == "b")
            #expect(outcome.result?.answers["model"]?.choice == "claude-a")
            #expect(outcome.attempts.map(\.reason) == ["http-401", "ok"])
            #expect(await fake.bodies.last?["model"] == nil, "Workers AI gets the schema-exact body")
        }
    }

    @Test func everyHostFailingReportsTheLastReason() async throws {
        let fake = FakeJev(["a": [.init(status: .tooManyRequests, body: "{}")]])
        try await withFakeJev(fake) { url, http in
            let outcome = await JevClient(hosts: [host("a", url("a"))], http: http, timing: Self.fast).ask(try Fixture.request())
            #expect(outcome.result == nil)
            #expect(outcome.failure == "http-429")
            #expect(await fake.calls("a") == 2)
            #expect(!outcome.summary.contains("rename tmp"))
        }
    }

    @Test func aSlowHostTimesOut() async throws {
        let fake = FakeJev(["a": [.init(body: Fixture.reply(), delay: .seconds(1))]])
        try await withFakeJev(fake) { url, http in
            let timing = JevClient.Timing(attemptTimeout: .milliseconds(150), retries: 0, deadline: .seconds(1))
            let outcome = await JevClient(hosts: [host("a", url("a"))], http: http, timing: timing).ask(try Fixture.request())
            #expect(outcome.failure == "timeout")
            #expect(outcome.milliseconds < 600)
        }
    }

    @Test func theDeadlineBoundsRetriesAndFailover() async throws {
        let slow = FakeJev.Step(body: Fixture.reply(), delay: .seconds(1))
        let fake = FakeJev(["a": [slow], "b": [slow]])
        try await withFakeJev(fake) { url, http in
            let timing = JevClient.Timing(attemptTimeout: .milliseconds(250), retries: 5, backoffInitial: .milliseconds(10),
                                          backoffMax: .milliseconds(10), deadline: .milliseconds(400))
            let client = JevClient(hosts: [host("a", url("a")), host("b", url("b"))], http: http, timing: timing)
            let outcome = await client.ask(try Fixture.request())
            #expect(outcome.failure == "timeout")
            #expect(outcome.milliseconds < 800)
            #expect(outcome.attempts.count <= 3)
        }
    }

    @Test func aReplyOutsideTheSchemaIsNotUsed() async throws {
        let fake = FakeJev(["a": [.init(body: #"{"model":"m","answers":{"model":{"type":"choice","choice":"claude-b"}},"usage":{"input_tokens":1,"output_tokens":1}}"#)]])
        try await withFakeJev(fake) { url, http in
            let client = JevClient(hosts: [host("a", url("a"))], http: http, timing: Self.fast, keepReplies: true)
            let outcome = await client.ask(try Fixture.request())
            #expect(outcome.failure == "schema-invalid")
            #expect(await fake.calls("a") == 1, "a bad reply is not retried")
            #expect(outcome.attempts.first?.reply?["model"] == .string("m"))
            #expect(outcome.attempts.first?.message?.contains("/answers/model") == true)
        }
    }

    @Test func unreadableRepliesFail() async throws {
        let fake = FakeJev(["a": [.init(body: "<html>gateway</html>")]])
        try await withFakeJev(fake) { url, http in
            let outcome = await JevClient(hosts: [host("a", url("a"))], http: http, timing: Self.fast).ask(try Fixture.request())
            #expect(outcome.failure == "unreadable-reply")
        }
    }

    /// The request schema's only limits (non-empty keys, two or more score criteria) are
    /// enforced by the Swift types, so every request that can be built passes it. The client
    /// still checks before sending, in case a newer schema is stricter.
    @Test func everyBuildableRequestPassesTheSchema() throws {
        #expect(JevRequestSchema.schema.validate(try Fixture.request().json).isEmpty)
        #expect(throws: QuestionError.self) { try JevQuestion.score("x", ["only one"]) }
        #expect(throws: QuestionError.self) { try SystemOneRequest(state: nil, questions: [("", .noul())]) }
    }

    @Test func noHostsFailsImmediately() async throws {
        let outcome = await JevClient(hosts: [], timing: Self.fast).ask(try Fixture.request())
        #expect(outcome.failure == "no-hosts")
    }

    @Test func cancellationStopsTheCall() async throws {
        let fake = FakeJev(["a": [.init(body: Fixture.reply(), delay: .seconds(1))]])
        try await withFakeJev(fake) { url, http in
            let timing = JevClient.Timing(attemptTimeout: .seconds(5), retries: 3, deadline: .seconds(5))
            let client = JevClient(hosts: [host("a", url("a"))], http: http, timing: timing)
            let request = try Fixture.request()
            let task = Task { await client.ask(request) }
            // Cancel once the call is in flight; a slow machine may take a while to send it.
            for _ in 0..<100 where await fake.calls("a") == 0 { try await Task.sleep(for: .milliseconds(20)) }
            let started = ContinuousClock.now
            task.cancel()
            let outcome = await task.value
            #expect(outcome.result == nil)
            #expect(ContinuousClock.now - started < .milliseconds(900))
            #expect(await fake.calls("a") == 1)
        }
    }

    /// A redirect could carry the bearer token to another server, so the shared client refuses it.
    @Test func redirectsAreNotFollowed() async throws {
        let fake = FakeJev(["a": [.init(status: .temporaryRedirect, body: "{}", location: "/b")],
                            "b": [.init(body: Fixture.reply())]])
        try await withFakeJev(fake) { url, _ in
            let outcome = await JevClient(hosts: [host("a", url("a"))], timing: Self.fast).ask(try Fixture.request())
            #expect(outcome.failure == "http-307")
            #expect(await fake.calls("b") == 0)
        }
    }
}
