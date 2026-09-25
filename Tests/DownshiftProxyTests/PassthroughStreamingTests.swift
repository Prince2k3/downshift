import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import ServiceLifecycle
import NIOCore
import Testing
@testable import DownshiftProxy

/// Records how far the fake upstream got, so tests can see when the proxy stops reading.
actor UpstreamProbe {
    var written = 0
    var aborted = false
    func wrote() { written += 1 }
    func abort() { aborted = true }
}

/// Runs a fake SSE upstream and the passthrough in front of it, both on ephemeral ports.
func withProxiedUpstream(
    chunks: Int, interval: Duration, probe: UpstreamProbe,
    _ body: @Sendable (_ proxyPort: Int, _ client: HTTPClient) async throws -> Void
) async throws {
    let router = Router()
    router.post("/v1/messages") { request, _ -> Response in
        let echo = try await request.body.collect(upTo: 1 << 20)
        return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: ResponseBody { writer in
            do {
                try await writer.write(ByteBuffer(string: "event: echo\ndata: \(String(buffer: echo))\n\n"))
                for i in 0..<chunks {
                    try await Task.sleep(for: interval)
                    try await writer.write(ByteBuffer(string: "data: \(i)\n\n"))
                    await probe.wrote()
                }
                try await writer.finish(nil)
            } catch {
                await probe.abort()
                throw error
            }
        })
    }
    let upstream = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    let client = HTTPClient.jevUpstream()
    do {
        try await upstream.test(.live) { upstreamClient in
            let port = try #require(upstreamClient.port)
            let proxy = Application(
                responder: PassthroughResponder(client: client, upstream: "http://localhost:\(port)",
                                                dumper: nil, logger: Logger(label: "test")),
                configuration: .init(address: .hostname("127.0.0.1", port: 0)))
            try await proxy.test(.live) { proxyClient in
                try await body(try #require(proxyClient.port), client)
            }
        }
    } catch {
        try await client.shutdown()
        throw error
    }
    try await client.shutdown()
}

@Suite struct PassthroughStreamingTests {
    @Test func chunksArriveIncrementallyAndBytesAreUnchanged() async throws {
        let probe = UpstreamProbe()
        try await withProxiedUpstream(chunks: 4, interval: .milliseconds(150), probe: probe) { port, client in
            var request = HTTPClientRequest(url: "http://localhost:\(port)/v1/messages?beta=true")
            request.method = .POST
            let payload = #"{"z":1,"a":"é é"}"#
            request.body = .bytes(ByteBuffer(string: payload))
            let start = ContinuousClock.now
            let response = try await client.execute(request, timeout: .seconds(10))
            #expect(response.status == .ok)
            #expect(response.headers["content-type"].first == "text/event-stream")

            var received = ""
            var firstChunkAt: Duration?
            for try await chunk in response.body {
                if firstChunkAt == nil { firstChunkAt = ContinuousClock.now - start }
                received += String(buffer: chunk)
            }
            let total = ContinuousClock.now - start
            // The echo event is sent before the first 150ms pause; a buffering proxy would
            // deliver nothing until all four chunks (600ms) were done.
            #expect(try #require(firstChunkAt) < .milliseconds(400))
            #expect(total >= .milliseconds(600))
            #expect(received == "event: echo\ndata: \(payload)\n\n" + (0..<4).map { "data: \($0)\n\n" }.joined())
        }
    }

    @Test func clientDisconnectCancelsTheUpstreamRequest() async throws {
        let probe = UpstreamProbe()
        try await withProxiedUpstream(chunks: 200, interval: .milliseconds(20), probe: probe) { port, client in
            var request = HTTPClientRequest(url: "http://localhost:\(port)/v1/messages")
            request.method = .POST
            request.body = .bytes(ByteBuffer(string: "{}"))
            // Read one chunk, then abandon the response: dropping the iterator cancels the
            // client request and closes the connection to the proxy.
            let reader = Task {
                let response = try await client.execute(request, timeout: .seconds(10))
                for try await _ in response.body { break }
            }
            try await reader.value

            let deadline = ContinuousClock.now + .seconds(3)
            while await !probe.aborted, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await probe.aborted, "upstream kept streaming after the client left")
            #expect(await probe.written < 200)
        }
    }

    @Test func unreachableUpstreamIsA502() async throws {
        let client = HTTPClient.jevUpstream(connectTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        let proxy = Application(
            responder: PassthroughResponder(client: client, upstream: "http://127.0.0.1:1",
                                            dumper: nil, logger: Logger(label: "test")),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await proxy.test(.router) { testClient in
            try await testClient.execute(uri: "/v1/messages", method: .post, body: ByteBuffer(string: "{}")) { response in
                #expect(response.status == .badGateway)
            }
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        try await client.shutdown()
    }

    /// SIGTERM semantics: graceful shutdown mid-stream lets the in-flight stream finish,
    /// then the service group exits.
    @Test func gracefulShutdownLetsTheStreamFinish() async throws {
        let probe = UpstreamProbe()
        try await withProxiedUpstream(chunks: 5, interval: .milliseconds(60), probe: probe) { upstreamPort, client in
            // Run a second proxy inside our own ServiceGroup so the test can trigger shutdown.
            let (portStream, portContinuation) = AsyncStream.makeStream(of: Int.self)
            let proxy = Application(
                responder: PassthroughResponder(client: client, upstream: "http://localhost:\(upstreamPort)",
                                                dumper: nil, logger: Logger(label: "test")),
                configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                onServerRunning: { portContinuation.yield($0.localAddress?.port ?? 0) })
            let group = ServiceGroup(configuration: .init(services: [proxy], logger: Logger(label: "test")))
            async let run: Void = group.run()
            var ports = portStream.makeAsyncIterator()
            let port = try #require(await ports.next())

            var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/v1/messages")
            request.method = .POST
            request.body = .bytes(ByteBuffer(string: "{}"))
            let response = try await client.execute(request, timeout: .seconds(10))
            var received = ""
            var iterator = response.body.makeAsyncIterator()
            received += String(buffer: try #require(await iterator.next()))
            await group.triggerGracefulShutdown()
            while let chunk = try await iterator.next() { received += String(buffer: chunk) }
            try await run

            #expect(received.hasSuffix((0..<5).map { "data: \($0)\n\n" }.joined()))
            #expect(await !probe.aborted)
        }
    }
}
