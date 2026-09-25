import Foundation
import HTTPTypes
import DownshiftCore
import NIOCore

/// Routes Codex Responses API requests that ask for the sentinel model, adds the sentinel to
/// the model picker, and shows each decision in the transcript as a commentary message.
/// Paths are relative to the `/codex` route.
public struct CodexInterceptor: ProxyInterceptor {
    public let engine: RoutingEngine
    /// Where API-key requests go; the route's upstream serves ChatGPT sign-in.
    public let apiUpstream: String

    public init(engine: RoutingEngine, apiUpstream: String = CodexAdapter.apiUpstream) {
        self.engine = engine
        self.apiUpstream = apiUpstream
    }

    static let sessionHeader = HTTPField.Name(CodexAdapter.sessionHeader)!
    static let accountHeader = HTTPField.Name(CodexAdapter.accountHeader)!

    public func rewriteRequest(method: HTTPRequest.Method, path: String, headers: HTTPFields,
                               body: ByteBuffer) async -> InterceptedRequest {
        let upstream = CodexAdapter.usesChatGPT(path: path, accountHeader: headers[Self.accountHeader]) ? nil : apiUpstream
        guard method == .post, path.hasSuffix("/responses"), var json = try? JSONValue.parse(body.readableBytesView),
              case .object = json else { return InterceptedRequest(body: body, upstream: upstream) }
        let (outcome, usage) = await engine.route(&json, headerSession: headers[Self.sessionHeader])
        return InterceptedRequest(body: ByteBuffer(bytes: json.serialized()), upstream: upstream,
                                  afterFirstEvent: outcome.map { ByteBuffer(string: CodexAdapter.decisionFrames($0)) },
                                  usage: usage)
    }

    public func buffersResponse(method: HTTPRequest.Method, path: String) -> Bool {
        method == .get && path.hasSuffix("/models")
    }

    /// Records the catalog, and returns it with the downshift row added.
    public func interceptResponse(method: HTTPRequest.Method, path: String, status: Int, body: ByteBuffer) async -> ByteBuffer? {
        guard status == 200, let json = try? JSONValue.parse(body.readableBytesView) else { return nil }
        await engine.observeCatalog(json)
        let adapter = engine.adapter as? CodexAdapter ?? CodexAdapter()
        return adapter.addingJevModel(json).map { ByteBuffer(bytes: $0.serialized()) }
    }

    /// A WebSocket `response.create` carries the same body as an HTTP request plus its
    /// `type`, so it is routed the same way, and the decision follows the upstream's first
    /// event as plain event messages. A manual one is sent unchanged, but still metered.
    public func interceptMessage(path: String, headers: HTTPFields, text: String) async -> InterceptedMessage? {
        guard var json = try? JSONValue.parse(text), json["type"]?.stringValue == "response.create" else { return nil }
        let routed = RouterModel.isRouted(json["model"]?.stringValue)
        let (outcome, usage) = await engine.route(&json, headerSession: headers[Self.sessionHeader])
        guard routed else { return InterceptedMessage(text: text, usage: usage) }
        return InterceptedMessage(text: json.serializedString(),
                                  afterNextReply: outcome.map { CodexAdapter.decisionEvents($0).map { $0.serializedString() } } ?? [],
                                  usage: usage)
    }

    public func upstreamError(_ message: String) -> JSONValue {
        ["error": ["message": .string(message), "type": "proxy_error"]]
    }
}
