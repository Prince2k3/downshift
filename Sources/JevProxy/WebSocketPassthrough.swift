import Foundation
import HTTPTypes
import HummingbirdWebSocket
import HummingbirdWSClient
import Logging
import NIOConcurrencyHelpers
import NIOCore

/// Bridges WebSocket upgrades to the upstream: the Codex app opens
/// `ws://127.0.0.1:<port>/codex/responses` before falling back to HTTP. The upstream
/// handshake happens first, so a refused upstream becomes `.dontUpgrade` and the request
/// takes the ordinary HTTP path (where the client sees the upstream's own status and
/// falls back as it would without jev).
///
/// Messages are relayed whole, in both directions, until either side closes. Headers are
/// forwarded like HTTP requests, minus the handshake's own; the upstream's handshake
/// response headers are not available from WSClient, so the client gets none of them.
public struct WebSocketPassthrough: Sendable {
    public typealias Handler = WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>

    /// Negotiated per hop, or set by WSClient itself (Host, Origin).
    static let handshakeHeaders: Set<String> = [
        "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions", "sec-websocket-accept", "origin",
    ]
    static let maxMessage = PassthroughResponder.maxRequestBody
    /// How long an upstream connection waits for the client side to start relaying.
    static let startTimeout: Duration = .seconds(10)
    static let handshakeTimeout: Duration = .seconds(15)

    struct HandshakeTimeout: Error, CustomStringConvertible {
        var description: String { "upstream websocket handshake timed out" }
    }

    let routes: [PassthroughResponder.Route]
    let logger: Logger

    /// Routes are tried longest prefix first.
    public init(routes: [PassthroughResponder.Route], logger: Logger) {
        self.routes = routes.sorted { $0.prefix.count > $1.prefix.count }
        self.logger = logger
    }

    public func shouldUpgrade(_ head: HTTPRequest) async -> ShouldUpgradeResult<Handler> {
        guard let path = head.path,
              let match = routes.lazy.compactMap({ route -> (PassthroughResponder.Route, String)? in
                  route.remainder(of: path).map { (route, $0) }
              }).first,
              let url = Self.webSocketURL(for: match.0.upstream + match.1) else { return .dontUpgrade }

        var headers = HTTPFields()
        for field in head.headerFields {
            let name = field.name.canonicalName
            if !hopByHopHeaders.contains(name) && !Self.handshakeHeaders.contains(name) { headers.append(field) }
        }
        let configuration = WebSocketClientConfiguration(maxFrameSize: Self.maxMessage, additionalHeaders: headers,
                                                         autoPing: .enabled(timePeriod: .seconds(30)))

        let upstream = UpstreamSocket()
        let logger = logger
        let requestPath = head.path.map { $0.split(separator: "?", maxSplits: 1).first.map(String.init) ?? $0 } ?? ""
        let rest = match.1
        let routePath = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
        let headerFields = head.headerFields
        let rewrite: MessageRewrite? = match.0.interceptor.map { interceptor -> MessageRewrite in
            { text in await interceptor.interceptMessage(path: routePath, headers: headerFields, text: text) }
        }
        Task {
            do {
                try await WebSocketClient.connect(url: url, configuration: configuration, logger: logger) { inbound, outbound, _ in
                    await upstream.connected(inbound: inbound, outbound: outbound)
                }
                upstream.connectionEnded(nil)
            } catch {
                upstream.connectionEnded(error)
            }
        }

        let handshake = Task {
            try await Task.sleep(for: Self.handshakeTimeout)
            upstream.connectionEnded(HandshakeTimeout())
            upstream.finish()
        }
        let connected = await upstream.waitUntilConnected()
        handshake.cancel()
        guard let socket = connected else {
            logger.warning("upstream websocket refused; falling back to HTTP",
                           metadata: ["path": "\(requestPath)", "error": "\(upstream.failure.map { "\($0)" } ?? "closed")"])
            return .dontUpgrade
        }
        logger.debug("websocket open", metadata: ["path": "\(requestPath)"])
        Task {
            // If the client goes away mid-upgrade the handler never runs; don't hold the upstream open.
            try? await Task.sleep(for: Self.startTimeout)
            if upstream.claimStart() { upstream.finish() }
        }
        return .upgrade([:]) { clientInbound, clientOutbound, _ in
            guard upstream.claimStart() else { return }
            defer { upstream.finish() }
            await Self.relay(client: (clientInbound, clientOutbound), upstream: socket, rewrite: rewrite)
            logger.debug("websocket closed", metadata: ["path": "\(requestPath)"])
        }
    }

    /// `https://host/path` → `wss://host/path`, `http` → `ws`.
    static func webSocketURL(for target: String) -> String? {
        if target.hasPrefix("https://") { return "wss://" + target.dropFirst("https://".count) }
        if target.hasPrefix("http://") { return "ws://" + target.dropFirst("http://".count) }
        return nil
    }

    typealias MessageRewrite = @Sendable (String) async -> InterceptedMessage?

    /// Copies messages both ways; when one side stops, closes the other and returns. With
    /// `rewrite`, client text messages go through the route's interceptor, and whatever it
    /// asks to add is sent to the client after the upstream's next message.
    ///
    /// Each intercepted message starts one response. Their usage contexts wait in order, and
    /// the upstream message that ends a response records its usage against the oldest (a
    /// socket runs one response at a time). Responses still open when the socket closes
    /// report no usage and aren't recorded.
    static func relay(client: (WebSocketInboundStream, WebSocketOutboundWriter),
                      upstream: (WebSocketInboundStream, WebSocketOutboundWriter),
                      rewrite: MessageRewrite? = nil) async {
        let pending = NIOLockedValueBox<[String]>([])
        let responses = NIOLockedValueBox<[UsageContext?]>([])
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await copy(from: client.0, to: upstream.1, text: { text in
                    guard let rewrite, let intercepted = await rewrite(text) else { return text }
                    pending.withLockedValue { $0.append(contentsOf: intercepted.afterNextReply) }
                    responses.withLockedValue { $0.append(intercepted.usage) }
                    return intercepted.text
                })
                try? await upstream.1.close(.normalClosure, reason: nil)
            }
            group.addTask {
                await copy(from: upstream.0, to: client.1, after: {
                    pending.withLockedValue { queued in defer { queued = [] }; return queued }
                }, text: { text in
                    guard rewrite != nil else { return text }
                    let (ends, reading) = UsageMeter.readMessage(text)
                    if ends {
                        let context: UsageContext?? = responses.withLockedValue { $0.isEmpty ? nil : $0.removeFirst() }
                        context??.record(reading)
                    }
                    return text
                })
                try? await client.1.close(.normalClosure, reason: nil)
            }
            await group.next()
            group.cancelAll()
        }
    }

    static func copy(from inbound: WebSocketInboundStream, to outbound: WebSocketOutboundWriter,
                     after: @Sendable () -> [String] = { [] },
                     text transform: @Sendable (String) async -> String = { $0 }) async {
        do {
            for try await message in inbound.messages(maxSize: maxMessage) {
                switch message {
                case .text(let text): try await outbound.write(.text(await transform(text)))
                case .binary(let buffer): try await outbound.write(.binary(buffer))
                }
                for extra in after() { try await outbound.write(.text(extra)) }
            }
        } catch {}
    }
}

/// The upstream half of a bridge: signals once the handshake finished (or failed), then keeps
/// the upstream connection's handler running until the client half is done.
final class UpstreamSocket: Sendable {
    typealias Socket = (WebSocketInboundStream, WebSocketOutboundWriter)

    private struct State {
        var socket: Socket?
        var resolved = false
        var waiter: CheckedContinuation<Socket?, Never>?
        var failure: (any Error)?
        var finished = false
        var holder: CheckedContinuation<Void, Never>?
        var started = false
    }
    private let state = NIOLockedValueBox(State())

    var failure: (any Error)? { state.withLockedValue { $0.failure } }

    /// Resolves `waitUntilConnected` with the upstream socket, then waits for `finish()`.
    func connected(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async {
        resolve((inbound, outbound))
        await withCheckedContinuation { continuation in
            let resume = state.withLockedValue { state -> Bool in
                if state.finished { return true }
                state.holder = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    /// The upstream connection is over, successfully or not; unblocks a waiter still waiting.
    func connectionEnded(_ error: (any Error)?) {
        state.withLockedValue { if !$0.resolved { $0.failure = error } }
        resolve(nil)
    }

    func waitUntilConnected() async -> Socket? {
        await withCheckedContinuation { continuation in
            let result = state.withLockedValue { state -> Socket?? in
                if state.resolved { return .some(state.socket) }
                state.waiter = continuation
                return .none
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    /// True for the first caller only: the relay starting, or the watchdog giving up on it.
    func claimStart() -> Bool {
        state.withLockedValue { state in
            defer { state.started = true }
            return !state.started
        }
    }

    /// Lets the upstream handler return, which closes the upstream connection.
    func finish() {
        let holder = state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            state.finished = true
            defer { state.holder = nil }
            return state.holder
        }
        holder?.resume()
    }

    private func resolve(_ socket: Socket?) {
        let waiter = state.withLockedValue { state -> CheckedContinuation<Socket?, Never>? in
            guard !state.resolved else { return nil }
            state.resolved = true
            state.socket = socket
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: socket)
    }
}
