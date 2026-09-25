import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import HummingbirdWSClient
import Logging
import NIOConcurrencyHelpers
import NIOCore
import Testing
@testable import JevProxy

/// What the fake upstream saw in each handshake.
final class HandshakeLog: Sendable {
    private let entries = NIOLockedValueBox<[(path: String, authority: String?, headers: HTTPFields)]>([])
    func record(_ head: HTTPRequest) { entries.withLockedValue { $0.append((head.path ?? "", head.authority, head.headerFields)) } }
    var all: [(path: String, authority: String?, headers: HTTPFields)] { entries.withLockedValue { $0 } }
}

/// Runs a fake WebSocket upstream (echoes each message back prefixed with "echo:", refuses
/// `/refuse`) and the real proxy application in front of it, as the `/codex` route.
func withWebSocketProxy(_ body: @Sendable (_ proxyPort: Int, _ handshakes: HandshakeLog) async throws -> Void) async throws {
    let handshakes = HandshakeLog()
    let router = Router()
    router.get("/refuse") { _, _ in Response(status: .methodNotAllowed) }
    let upstream = Application(
        router: router,
        server: .http1WebSocketUpgrade(configuration: .init(ws: .init(maxFrameSize: 1 << 22))) { head, _, _ in
            handshakes.record(head)
            if head.path?.hasPrefix("/refuse") == true { return .dontUpgrade }
            if head.path?.hasPrefix("/bye") == true {
                return .upgrade([:]) { _, outbound, _ in try await outbound.write(.text("bye")) }
            }
            return .upgrade([:]) { inbound, outbound, _ in
                for try await message in inbound.messages(maxSize: 1 << 22) {
                    switch message {
                    case .text(let text): try await outbound.write(.text("echo:" + text))
                    case .binary(var buffer):
                        var reply = ByteBuffer(string: "echo:")
                        reply.writeBuffer(&buffer)
                        try await outbound.write(.binary(reply))
                    }
                }
            }
        },
        configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    let client = HTTPClient.jevUpstream()
    do {
        try await upstream.test(.live) { upstreamClient in
            let port = try #require(upstreamClient.port)
            let configuration = ProxyServer.Configuration(port: 0, upstream: "http://127.0.0.1:1",
                                                          codexUpstream: "http://localhost:\(port)")
            let proxy = ProxyServer.makeApplication(configuration, client: client, dumper: nil, logger: Logger(label: "test"))
            try await proxy.test(.live) { proxyClient in
                try await body(try #require(proxyClient.port), handshakes)
            }
        }
    } catch {
        try await client.shutdown()
        throw error
    }
    try await client.shutdown()
}

@Suite struct WebSocketPassthroughTests {
    let logger = Logger(label: "test-client")

    @Test func messagesRelayBothWaysAndThePrefixIsStripped() async throws {
        try await withWebSocketProxy { port, handshakes in
            let large = String(repeating: "x", count: 200_000)  // well past the 16 KiB default frame size
            let replies = NIOLockedValueBox<[String]>([])
            var headers = HTTPFields()
            headers[.authorization] = "Bearer secret"
            headers[HTTPField.Name("chatgpt-account-id")!] = "acct"
            try await WebSocketClient.connect(
                url: "ws://localhost:\(port)/codex/responses?stream=1",
                configuration: .init(maxFrameSize: 1 << 22, additionalHeaders: headers), logger: logger
            ) { inbound, outbound, _ in
                try await outbound.write(.text("hello"))
                try await outbound.write(.text(large))
                try await outbound.write(.binary(ByteBuffer(bytes: [0, 1, 2])))
                var received = 0
                for try await message in inbound.messages(maxSize: 1 << 22) {
                    switch message {
                    case .text(let text): replies.withLockedValue { $0.append(text) }
                    case .binary(let buffer): replies.withLockedValue { $0.append("bin:\(Array(buffer.readableBytesView))") }
                    }
                    received += 1
                    if received == 3 { break }
                }
                try await outbound.close(.normalClosure, reason: nil)
            }
            #expect(replies.withLockedValue { $0 } == ["echo:hello", "echo:" + large, "bin:\(Array("echo:".utf8) + [0, 1, 2])"])

            let handshake = try #require(handshakes.all.first)
            #expect(handshake.path == "/responses?stream=1")
            #expect(handshake.headers[.authorization] == "Bearer secret")
            #expect(handshake.headers[HTTPField.Name("chatgpt-account-id")!] == "acct")
            // Exactly one of each: ours, not the client's copies alongside.
            #expect(handshake.headers[values: .secWebSocketKey].count == 1)
            // WSClient sets Host for the upstream; the client's (the proxy's address) isn't forwarded.
            #expect(handshake.authority != nil && handshake.authority != "localhost:\(port)")
        }
    }

    @Test func clientClosingFinishesPromptly() async throws {
        try await withWebSocketProxy { port, _ in
            // The echo upstream never closes on its own; closing from the client must end
            // both halves instead of leaving the relay waiting on the upstream.
            let start = ContinuousClock.now
            try await WebSocketClient.connect(url: "ws://localhost:\(port)/codex/responses", logger: logger) { _, outbound, _ in
                try await outbound.close(.normalClosure, reason: nil)
            }
            #expect(ContinuousClock.now - start < .seconds(5))
        }
    }

    @Test func upstreamClosingClosesTheClient() async throws {
        try await withWebSocketProxy { port, _ in
            let received = NIOLockedValueBox<[String]>([])
            let start = ContinuousClock.now
            try await WebSocketClient.connect(url: "ws://localhost:\(port)/codex/bye", logger: logger) { inbound, _, _ in
                for try await case .text(let text) in inbound.messages(maxSize: 1 << 16) {
                    received.withLockedValue { $0.append(text) }
                }
            }
            #expect(received.withLockedValue { $0 } == ["bye"])
            #expect(ContinuousClock.now - start < .seconds(5))
        }
    }

    @Test func refusedUpstreamFallsBackToHTTP() async throws {
        try await withWebSocketProxy { port, handshakes in
            await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
                try await WebSocketClient.connect(url: "ws://localhost:\(port)/codex/refuse", logger: logger) { _, _, _ in }
            }
            #expect(handshakes.all.map(\.path) == ["/refuse"])
        }
    }

    @Test func unreachableUpstreamIsNotUpgraded() async throws {
        try await withWebSocketProxy { port, _ in
            // The root route points at port 1, where nothing listens.
            await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
                try await WebSocketClient.connect(url: "ws://localhost:\(port)/v1/messages", logger: logger) { _, _, _ in }
            }
        }
    }

    @Test func webSocketURLs() {
        #expect(WebSocketPassthrough.webSocketURL(for: "https://chatgpt.com/backend-api/codex/responses") == "wss://chatgpt.com/backend-api/codex/responses")
        #expect(WebSocketPassthrough.webSocketURL(for: "http://localhost:8080/x?y=1") == "ws://localhost:8080/x?y=1")
        #expect(WebSocketPassthrough.webSocketURL(for: "ftp://x") == nil)
    }
}
