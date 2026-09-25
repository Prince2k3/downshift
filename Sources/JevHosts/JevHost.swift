import DownshiftCore

/// One route to Jev: where to send a systemOne request, how to authenticate, and how the host
/// wraps the request and response. Jev itself is the same everywhere, so hosts differ only here.
/// Building the HTTP request and reading the reply are pure, so every host is testable offline.
public struct JevHost: Sendable, Hashable {
    /// How a host wraps Jev on the wire.
    public enum WireFormat: String, Sendable, Hashable, CaseIterable {
        /// TypeSafe's native `POST /v1/systemone`, also mirrored by OpenRouter's Decisions
        /// endpoint: `{state, questions, model}` in, Jev's response out (plus host extras).
        case systemOne = "systemone"
        /// Cloudflare Workers AI `ai/run/<model>`: the schema-exact request in, and the answer
        /// wrapped as `{result, success, errors}`.
        case workersAI = "workers-ai"
        /// Vercel AI Gateway's evaluation-model endpoint: the schema-exact request in, the model
        /// id in a header, and the AI SDK's evaluation result out.
        case vercel
    }

    public struct HTTPRequest: Sendable, Hashable {
        public var url: String
        /// Includes the credential; never log these.
        public var headers: [(name: String, value: String)]
        public var body: JSONValue

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.url == rhs.url && lhs.body == rhs.body
                && lhs.headers.map { [$0.name, $0.value] } == rhs.headers.map { [$0.name, $0.value] }
        }
        public func hash(into hasher: inout Hasher) { hasher.combine(url); hasher.combine(body) }
    }

    /// Why a reply could not be read. `message` is the host's own short error text, never a body.
    public struct ReplyError: Error, Sendable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    public var id: String
    public var format: WireFormat
    /// The full endpoint URL.
    public var url: String
    public var apiKey: String
    /// Jev's model id on this host, e.g. `jev-latest` or `typesafe/jev`.
    public var model: String

    public init(id: String, format: WireFormat, url: String, apiKey: String, model: String) {
        self.id = id
        self.format = format
        self.url = url
        self.apiKey = apiKey
        self.model = model
    }

    public func httpRequest(_ request: SystemOneRequest) -> HTTPRequest {
        var headers: [(name: String, value: String)] = [
            ("authorization", "Bearer \(apiKey)"),
            ("content-type", "application/json"),
            ("accept", "application/json"),
            ("user-agent", "downshift"),
        ]
        switch format {
        case .systemOne:
            return HTTPRequest(url: url, headers: headers, body: request.wireBody(model: model))
        case .workersAI:
            return HTTPRequest(url: url, headers: headers, body: request.json)
        case .vercel:
            headers += [
                ("ai-model-id", model),
                ("ai-evaluation-model-specification-version", "4"),
                ("ai-gateway-protocol-version", "0.0.1"),
            ]
            return HTTPRequest(url: url, headers: headers, body: request.json)
        }
    }

    /// Turns a successful (2xx) reply into Jev's response shape, `{model, answers, usage}`,
    /// ready for schema validation. Only the host's own envelope is removed or renamed; the
    /// answers are passed through as sent, so the schema still checks what Jev said.
    public func normalize(_ body: JSONValue) throws -> JSONValue {
        switch format {
        case .systemOne:
            return Self.project(body, fallbackModel: model)
        case .workersAI:
            guard body["success"]?.boolValue != false, let result = body["result"], result.objectValue != nil else {
                throw ReplyError(message: Self.errorMessage(body) ?? "no result in the Workers AI reply")
            }
            return Self.project(result, fallbackModel: model)
        case .vercel:
            // The AI SDK carries choice/score confidence in provider metadata, keyed by
            // question, and names token counts in camelCase.
            var body = body
            if case .object(var answers)? = body["answers"],
               let confidence = body["providerMetadata"]?["typesafe"]?["confidence"]?.objectValue {
                for entry in confidence.entries where answers[entry.key]?["confidence"] == nil {
                    guard case .object(var answer)? = answers[entry.key], answer["type"]?.stringValue != "noul" else { continue }
                    answer["confidence"] = entry.value
                    answers[entry.key] = .object(answer)
                }
                body["answers"] = .object(answers)
            }
            if let usage = body["usage"], usage["input_tokens"] == nil,
               let input = usage["inputTokens"], let output = usage["outputTokens"] {
                body["usage"] = ["input_tokens": input, "output_tokens": output]
            }
            let modelId = body["model"]?.stringValue ?? body["modelId"]?.stringValue ?? body["response"]?["modelId"]?.stringValue
            if let modelId { body["model"] = .string(modelId) }
            return Self.project(body, fallbackModel: model)
        }
    }

    /// Keeps the schema's three top-level keys and drops what hosts add around them (an id,
    /// provider name, or `usage.cost`). A missing `model` is filled from the host's model id.
    static func project(_ body: JSONValue, fallbackModel: String) -> JSONValue {
        guard body.objectValue != nil else { return body }
        var out = JSONObject()
        out["model"] = body["model"] ?? .string(fallbackModel)
        if let answers = body["answers"] { out["answers"] = answers }
        if let usage = body["usage"] {
            if usage.objectValue != nil {
                var tokens = JSONObject()
                if let input = usage["input_tokens"] { tokens["input_tokens"] = input }
                if let output = usage["output_tokens"] { tokens["output_tokens"] = output }
                out["usage"] = .object(tokens)
            } else {
                out["usage"] = usage
            }
        }
        return .object(out)
    }

    /// A short error message from any host's error envelope.
    public static func errorMessage(_ body: JSONValue?) -> String? {
        guard let body else { return nil }
        if let errors = body["errors"]?.arrayValue, let first = errors.first {
            return first["message"]?.stringValue ?? first.stringValue
        }
        if let error = body["error"] {
            return error["message"]?.stringValue ?? error.stringValue
        }
        return body["message"]?.stringValue ?? body["detail"]?.stringValue
    }
}
