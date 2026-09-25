import Foundation
import HTTPTypes
import JevCore
import NIOCore

/// A request after its interceptor has seen it.
public struct InterceptedRequest: Sendable {
    public var body: ByteBuffer
    /// An upstream base to use instead of the route's.
    public var upstream: String?
    /// Bytes to insert after the first Server-Sent Event of a successful streamed response.
    public var afterFirstEvent: ByteBuffer?
    /// Where to record the tokens a successful response reports, if anywhere.
    public var usage: UsageContext?

    public init(body: ByteBuffer, upstream: String? = nil, afterFirstEvent: ByteBuffer? = nil, usage: UsageContext? = nil) {
        self.body = body
        self.upstream = upstream
        self.afterFirstEvent = afterFirstEvent
        self.usage = usage
    }
}

/// A client WebSocket message after its interceptor has seen it.
public struct InterceptedMessage: Sendable {
    public var text: String
    /// Messages to send the client after the upstream's next message.
    public var afterNextReply: [String]
    /// Where to record the tokens of the response this message starts; nil records nothing.
    public var usage: UsageContext?

    public init(text: String, afterNextReply: [String] = [], usage: UsageContext? = nil) {
        self.text = text
        self.afterNextReply = afterNextReply
        self.usage = usage
    }
}

/// Per-route hooks into the passthrough. Every request body is already buffered; an
/// interceptor may rewrite it, may ask for a response to be buffered so it can be read or
/// replaced (the model catalog), and may add events to a streamed response. Everything else
/// streams through untouched.
public protocol ProxyInterceptor: Sendable {
    /// `path` is the path relative to the route, without the query string.
    func rewriteRequest(method: HTTPRequest.Method, path: String, headers: HTTPFields, body: ByteBuffer) async -> InterceptedRequest
    func buffersResponse(method: HTTPRequest.Method, path: String) -> Bool
    /// Reads a buffered response; a non-nil result replaces its body.
    func interceptResponse(method: HTTPRequest.Method, path: String, status: Int, body: ByteBuffer) async -> ByteBuffer?
    /// Rewrites one client-to-upstream WebSocket text message; nil forwards it unchanged.
    func interceptMessage(path: String, headers: HTTPFields, text: String) async -> InterceptedMessage?
    /// The body of the 502 sent when the upstream can't be reached, in the API's error shape.
    func upstreamError(_ message: String) -> JSONValue
}

extension ProxyInterceptor {
    public func interceptMessage(path: String, headers: HTTPFields, text: String) async -> InterceptedMessage? { nil }

    /// The Messages API error shape, so Claude Code shows the message instead of a parse error.
    public func upstreamError(_ message: String) -> JSONValue {
        ["type": "error", "error": ["type": "api_error", "message": .string(message)]]
    }
}

/// Routes Claude Messages API requests that ask for the sentinel model, and reads the
/// account's model catalog from `GET /v1/models`.
public struct ClaudeInterceptor: ProxyInterceptor {
    public let engine: RoutingEngine

    public init(engine: RoutingEngine) { self.engine = engine }

    public func rewriteRequest(method: HTTPRequest.Method, path: String, headers: HTTPFields,
                               body: ByteBuffer) async -> InterceptedRequest {
        guard method == .post, path.hasPrefix("/v1/messages"), var json = try? JSONValue.parse(body.readableBytesView),
              case .object = json else { return InterceptedRequest(body: body) }
        let session = HTTPField.Name(ClaudeAdapter.sessionHeader).flatMap { headers[$0] }
        // Token counting must name a real model too, but is not a turn and must not ask Jev.
        let routed = await engine.route(&json, headerSession: session, decide: path == "/v1/messages")
        return InterceptedRequest(body: ByteBuffer(bytes: json.serialized()), usage: routed.usage)
    }

    public func buffersResponse(method: HTTPRequest.Method, path: String) -> Bool {
        method == .get && path == "/v1/models"
    }

    /// The catalog passes through byte for byte.
    public func interceptResponse(method: HTTPRequest.Method, path: String, status: Int, body: ByteBuffer) async -> ByteBuffer? {
        guard status == 200, let json = try? JSONValue.parse(body.readableBytesView) else { return nil }
        await engine.observeCatalog(json)
        return nil
    }
}
