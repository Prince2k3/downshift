import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import DownshiftCore
import Logging
import NIOCore
import NIOHTTP1

/// Headers that belong to one hop and must not be forwarded (RFC 9110 §7.6.1), plus the
/// ones AsyncHTTPClient/Hummingbird recompute for the new connection.
let hopByHopHeaders: Set<String> = [
    "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length",
]

/// Forwards every request to its route's upstream and streams the response back. A route's
/// interceptor may rewrite the (buffered) request body and read chosen responses; everything
/// else passes through unchanged. With a dump directory it records raw request and response
/// bodies as fixtures (credentials redacted).
public struct PassthroughResponder: HTTPResponder {
    public typealias Context = BasicRequestContext

    public static let maxRequestBody = 64 * 1024 * 1024

    /// A path prefix served by one upstream. The prefix is stripped before forwarding, so
    /// `/codex/responses` with upstream `https://chatgpt.com/backend-api/codex` goes to
    /// `https://chatgpt.com/backend-api/codex/responses`. The empty prefix matches everything.
    public struct Route: Sendable {
        public var prefix: String
        public var upstream: String
        /// Rewrites requests and reads responses for this route; nil is a plain passthrough.
        public var interceptor: (any ProxyInterceptor)?

        public init(prefix: String, upstream: String, interceptor: (any ProxyInterceptor)? = nil) {
            self.prefix = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            self.upstream = upstream.hasSuffix("/") ? String(upstream.dropLast()) : upstream
            self.interceptor = interceptor
        }

        /// The upstream URL for `uri` (path plus query), or nil if this route does not match.
        func target(for uri: String) -> String? {
            remainder(of: uri).map { upstream + $0 }
        }

        /// `uri` with the prefix stripped, or nil if this route does not match.
        func remainder(of uri: String) -> String? {
            if prefix.isEmpty { return uri }
            guard uri.hasPrefix(prefix) else { return nil }
            let rest = uri.dropFirst(prefix.count)
            guard rest.isEmpty || rest.first == "/" || rest.first == "?" else { return nil }
            return String(rest)
        }
    }

    /// The most a buffered response (the model catalog) may hold.
    public static let maxBufferedResponse = 16 * 1024 * 1024

    let client: HTTPClient
    let routes: [Route]
    let dumper: FixtureDumper?
    let logger: Logger

    /// Routes are tried longest prefix first.
    public init(client: HTTPClient, routes: [Route], dumper: FixtureDumper?, logger: Logger) {
        self.client = client
        self.routes = routes.sorted { $0.prefix.count > $1.prefix.count }
        self.dumper = dumper
        self.logger = logger
    }

    public init(client: HTTPClient, upstream: String, dumper: FixtureDumper?, logger: Logger) {
        self.init(client: client, routes: [Route(prefix: "", upstream: upstream)], dumper: dumper, logger: logger)
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        // Claude Code and the Codex app probe the base URL with HEAD before the first request;
        // answer locally so the probe works whatever the upstream does with HEAD (plan bug #7).
        if request.method == .head { return Response(status: .ok) }
        guard let (route, rest) = routes.lazy.compactMap({ route in route.remainder(of: request.uri.string).map { (route, $0) } }).first else {
            return Response(status: .notFound, body: ResponseBody(byteBuffer: ByteBuffer(string: "dshift: no route for \(request.uri.path)\n")))
        }
        let path = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
        var body = try await request.body.collect(upTo: Self.maxRequestBody)
        let exchange = await dumper?.begin(method: request.method.rawValue, uri: request.uri.string,
                                           headers: request.headers, body: body)
        let bufferResponse = route.interceptor?.buffersResponse(method: request.method, path: path) ?? false
        var afterFirstEvent: ByteBuffer?
        var usage: UsageContext?
        var upstreamBase = route.upstream
        if let interceptor = route.interceptor {
            let intercepted = await interceptor.rewriteRequest(method: request.method, path: path, headers: request.headers, body: body)
            body = intercepted.body
            afterFirstEvent = intercepted.afterFirstEvent
            usage = intercepted.usage
            if let upstream = intercepted.upstream { upstreamBase = upstream.hasSuffix("/") ? String(upstream.dropLast()) : upstream }
        }
        let target = upstreamBase + rest

        var outbound = HTTPClientRequest(url: target)
        outbound.method = HTTPMethod(rawValue: request.method.rawValue)
        for field in request.headers where !hopByHopHeaders.contains(field.name.canonicalName) {
            // A buffered response is parsed, so ask for it uncompressed.
            if bufferResponse && field.name == .acceptEncoding { continue }
            outbound.headers.add(name: field.name.rawName, value: field.value)
        }
        if body.readableBytes > 0 || request.method == .post || request.method == .put || request.method == .patch {
            outbound.body = .bytes(body)
        }

        let upstreamResponse: HTTPClientResponse
        do {
            upstreamResponse = try await client.execute(outbound, timeout: .hours(2))
        } catch {
            logger.warning("upstream request failed", metadata: ["uri": "\(request.uri.path)", "error": "\(error)"])
            await exchange?.fail("\(error)")
            let message = "dshift: upstream unreachable"
            let error = route.interceptor?.upstreamError(message)
                ?? ["type": "error", "error": ["type": "api_error", "message": .string(message)]]
            return Response(status: .badGateway, headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: ByteBuffer(bytes: error.serialized())))
        }

        var headers = HTTPFields()
        for (name, value) in upstreamResponse.headers where !hopByHopHeaders.contains(name.lowercased()) {
            if let fieldName = HTTPField.Name(name) { headers.append(HTTPField(name: fieldName, value: value)) }
        }
        let status = HTTPResponse.Status(code: Int(upstreamResponse.status.code),
                                         reasonPhrase: upstreamResponse.status.reasonPhrase)
        await exchange?.responseHead(status: status.code, headers: upstreamResponse.headers)
        logger.debug("proxied", metadata: ["method": "\(request.method)", "path": "\(request.uri.path)", "status": "\(status.code)"])

        if bufferResponse, let interceptor = route.interceptor {
            let data: ByteBuffer
            do {
                data = try await upstreamResponse.body.collect(upTo: Self.maxBufferedResponse)
            } catch {
                await exchange?.fail("\(error)")
                throw error
            }
            await exchange?.responseChunk(data)
            await exchange?.finish()
            let replaced = await interceptor.interceptResponse(method: request.method, path: path, status: status.code, body: data)
            // Content-Length is recomputed for the body actually sent.
            return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: replaced ?? data))
        }

        let upstreamBody = upstreamResponse.body
        let succeeded = (200..<300).contains(status.code)
        let frames = succeeded ? afterFirstEvent : nil
        // A compressed body can't be read as it passes; that reply goes unmetered.
        let encoding = upstreamResponse.headers.first(name: "content-encoding")?.lowercased() ?? "identity"
        let metered = succeeded && encoding == "identity" ? usage : nil
        return Response(status: status, headers: headers, body: ResponseBody { writer in
            var injector = frames.map(SSEInjector.init(frames:))
            var meter = metered.map { _ in UsageMeter() }
            // Tokens already billed are recorded even if the client goes away mid-reply.
            defer { metered?.record(meter?.finish()) }
            // If the client goes away, `write` throws, this task is cancelled, and dropping the
            // upstream body iterator cancels the upstream request (plan bug #4).
            do {
                for try await chunk in upstreamBody {
                    await exchange?.responseChunk(chunk)
                    meter?.feed(chunk)
                    if injector == nil {
                        try await writer.write(chunk)
                    } else {
                        for part in injector!.feed(chunk) { try await writer.write(part) }
                    }
                }
                if let rest = injector?.finish() { try await writer.write(rest) }
                await exchange?.finish()
                try await writer.finish(nil)
            } catch {
                await exchange?.fail("stream ended: \(error)")
                throw error
            }
        })
    }
}

/// Writes one directory entry per exchange: `NNNN-<method>-<path>.request.body` holds the
/// exact request bytes (used for the JSONValue round-trip tests), `.response.body` the exact
/// response bytes, and `.meta.json` the method, path, status and redacted headers.
/// The directory is 0700 and files are 0600 because bodies contain prompts.
public actor FixtureDumper {
    static let redacted: Set<String> = [
        "authorization", "x-api-key", "cookie", "set-cookie", "chatgpt-account-id",
        "openai-organization", "openai-project", "anthropic-organization-id", "cf-ray",
    ]

    let directory: URL
    var counter = 0

    public init(directory: String) throws {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func begin(method: String, uri: String, headers: HTTPFields, body: ByteBuffer) -> Exchange {
        counter += 1
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let slug = path.split(separator: "/").joined(separator: "_").filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let base = directory.appendingPathComponent(String(format: "%04d-%@-%@", counter, method, slug.isEmpty ? "root" : slug))
        let requestHeaders = headers.map { field -> (String, String) in
            let name = field.name.canonicalName
            return (name, Self.redacted.contains(name) ? "<redacted>" : field.value)
        }
        return Exchange(base: base, method: method, uri: uri, requestHeaders: requestHeaders, requestBody: Data(buffer: body))
    }

    public final class Exchange: @unchecked Sendable {
        // Only touched from the single request task that owns the exchange.
        let base: URL
        var meta: [(String, Any)]
        var response: FileHandle?

        init(base: URL, method: String, uri: String, requestHeaders: [(String, String)], requestBody: Data) {
            self.base = base
            meta = [("method", method), ("uri", uri), ("requestHeaders", requestHeaders.map { [$0.0, $0.1] })]
            Self.write(requestBody, to: base.appendingPathExtension("request.body"))
        }

        func responseHead(status: Int, headers: HTTPHeaders) async {
            meta.append(("status", status))
            meta.append(("responseHeaders", headers.map { name, value in
                [name.lowercased(), FixtureDumper.redacted.contains(name.lowercased()) ? "<redacted>" : value]
            }))
            let url = base.appendingPathExtension("response.body")
            Self.write(Data(), to: url)
            response = try? FileHandle(forWritingTo: url)
        }

        func responseChunk(_ chunk: ByteBuffer) async {
            try? response?.write(contentsOf: Data(buffer: chunk))
        }

        func finish() async { close(outcome: "complete") }
        func fail(_ reason: String) async { close(outcome: reason) }

        private func close(outcome: String) {
            try? response?.close()
            response = nil
            meta.append(("outcome", outcome))
            let object = Dictionary(meta, uniquingKeysWith: { $1 })
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                Self.write(data, to: base.appendingPathExtension("meta.json"))
            }
        }

        static func write(_ data: Data, to url: URL) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}

extension Data {
    init(buffer: ByteBuffer) {
        self = buffer.withUnsafeReadableBytes { Data($0) }
    }
}

extension HTTPClient {
    /// The client every upstream call uses. Redirects are never followed (a redirect must not
    /// carry the user's credentials elsewhere), bodies are passed through still compressed, and
    /// connection retries give up after `connectTimeout` so an unreachable host becomes a 502
    /// instead of hanging until the request deadline.
    public static func jevUpstream(connectTimeout: TimeAmount = .seconds(5)) -> HTTPClient {
        var configuration = HTTPClient.Configuration(redirectConfiguration: .disallow, decompression: .disabled)
        configuration.timeout.connect = connectTimeout
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }
}
