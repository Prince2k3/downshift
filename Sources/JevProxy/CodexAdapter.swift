import Crypto
import Foundation
import JevCore

/// What a Codex Responses API request looks like to the router: pure functions over the
/// parsed body, ported from Node's `codex-proxy.mjs`.
public struct CodexAdapter: CLIAdapter {
    public var app: String { "codex" }

    public static let sessionHeader = "session-id"
    public static let accountHeader = "chatgpt-account-id"
    /// Where requests without ChatGPT sign-in (an API key) go.
    public static let apiUpstream = "https://api.openai.com/v1"

    /// `JEV_CODEX_<TIER>_MODEL` overrides.
    public var environment: [String: String]

    public init(environment: [String: String] = [:]) { self.environment = environment }

    // MARK: Turns

    nonisolated(unsafe) private static let noise = [
        try! Regex(#"<system[-_]reminder>[\s\S]*?</system[-_]reminder>"#).ignoresCase(),
        try! Regex(#"<current_datetime>[\s\S]*?</current_datetime>"#).ignoresCase(),
        try! Regex(#"<environment_context>[\s\S]*?</environment_context>"#).ignoresCase(),
    ]
    nonisolated(unsafe) private static let titlePrompt = try! Regex(#"^Generate a concise, single-line task title\b"#).ignoresCase()
    nonisolated(unsafe) private static let explainCommand = try! Regex(#"^\$jev-explain\b"#).ignoresCase()

    /// A string, or the `text`/`input_text` parts of a content array joined by newlines.
    static func textOf(_ content: JSONValue?) -> String {
        switch content {
        case .string(let string)?: return string
        case .array(let parts)?:
            return parts.filter { ["text", "input_text"].contains($0["type"]?.stringValue ?? "") }
                .map { $0["text"]?.stringValue ?? "" }
                .joined(separator: "\n")
        default: return ""
        }
    }

    static func cleanPrompt(_ text: String) -> String {
        noise.reduce(text) { $0.replacing($1, with: "") }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isAuxiliaryPrompt(_ prompt: String) -> Bool { prompt.firstMatch(of: titlePrompt) != nil }

    /// The Codex app sends its thread-title call with the same tools and headers as a real
    /// turn; only the turn metadata says what triggered it.
    static func isAuxiliaryCall(_ body: JSONValue) -> Bool {
        guard let metadata = turnMetadata(body) else { return false }
        return metadata["turn_trigger"]?.stringValue == "thread_title" || metadata["thread_source"]?.stringValue == "thread_title"
    }

    /// `client_metadata["x-codex-turn-metadata"]`, itself a JSON string.
    static func turnMetadata(_ body: JSONValue) -> JSONValue? {
        body["client_metadata"]?["x-codex-turn-metadata"]?.stringValue.flatMap { try? JSONValue.parse($0) }
    }

    /// User text that starts a new Codex turn, or nil. A turn's opening request lists
    /// `additional_tools`; a request that ends in tool output continues a turn.
    public func newTurnPrompt(_ body: JSONValue) -> String? {
        guard let input = body["input"]?.arrayValue,
              input.contains(where: { $0["type"]?.stringValue == "additional_tools" }),
              !Self.isAuxiliaryCall(body) else { return nil }
        for item in input.reversed() {
            let type = item["type"]?.stringValue
            if type == "function_call_output" || type == "custom_tool_call_output" { return nil }
            guard item["role"]?.stringValue == "user" else { continue }
            let prompt = Self.cleanPrompt(Self.textOf(item["content"]))
            if !prompt.isEmpty && !Self.isAuxiliaryPrompt(prompt) { return prompt }
        }
        return nil
    }

    public func isExplainRequest(_ prompt: String) -> Bool {
        prompt.contains("<jev-explain>") || prompt.firstMatch(of: Self.explainCommand) != nil
    }

    public func isAgentTurn(_ body: JSONValue) -> Bool {
        newTurnPrompt(body).map { !isExplainRequest($0) } ?? false
    }

    public func prepare(_ body: inout JSONValue) {}

    public func sessionOf(_ body: JSONValue) -> String {
        body["client_metadata"]?["session_id"]?.stringValue ?? ""
    }

    /// `prompt_cache_key` is per conversation (sub-agents get their own); the turn metadata
    /// and the first user message are fallbacks.
    public func conversationKey(_ body: JSONValue) -> String {
        func text(_ value: JSONValue?) -> String? {
            guard let value, value != .null else { return nil }
            return value.stringValue ?? value.serializedString()
        }
        let firstUser = body["input"]?.arrayValue?.first { $0["role"]?.stringValue == "user" }
        let stable = text(body["prompt_cache_key"])
            ?? text(body["client_metadata"]?["x-codex-turn-metadata"])
            ?? "\(body["instructions"]?.stringValue ?? "")|\(Self.textOf(firstUser?["content"]))"
        let digest = Insecure.SHA1.hash(data: Data(stable.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    public func contextTokens(_ body: JSONValue) -> Int {
        let length = (body["input"] ?? .null).serializedString().utf16.count
        return Int((Double(length) / 4).rounded())
    }

    // MARK: Catalog

    public func catalogEntries(_ body: JSONValue) -> [JSONValue]? {
        guard let models = body["models"]?.arrayValue, !models.isEmpty else { return nil }
        return models
    }

    /// Exact GPT models in the account's catalog. Unlike Node, hidden models (internal
    /// reviewers, reserved slugs) are never offered, since the user can't pick them either.
    public func models(catalog: [JSONValue]) -> [RoutableModel] {
        let models = catalog.compactMap { entry -> RoutableModel? in
            guard let slug = entry["slug"]?.stringValue, slug != RouterModel.id,
                  entry["supported_in_api"] != .bool(false),
                  entry["visibility"]?.stringValue != "hide",
                  let tier = tier(of: slug) else { return nil }
            let description = [
                entry["display_name"]?.stringValue,
                entry["description"]?.stringValue,
                entry["context_window"]?.intValue.map { "\($0) context tokens" },
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
            return RoutableModel(id: slug, tier: tier, description: description)
        }
        guard models.isEmpty else { return models }
        return Tier.allCases.map { tier in
            let id = CodexModel.id(for: tier, environment: environment)
            return RoutableModel(id: id, tier: tier, description: id)
        }
    }

    public func model(for tier: Tier, in models: [RoutableModel]) -> String {
        models.first { $0.tier == tier }?.id ?? CodexModel.id(for: tier, environment: environment)
    }

    public func tier(of model: String) -> Tier? { CodexModel.tier(of: model, environment: environment) }

    /// Sets the model, and resets a reasoning effort the model doesn't support to its default
    /// (Codex composes the request for the model it thinks it is talking to).
    public func apply(_ body: inout JSONValue, tier: Tier, model: String, catalog: [JSONValue]) {
        body["model"] = .string(model)
        guard let effort = body["reasoning"]?["effort"]?.stringValue,
              let info = catalog.first(where: { $0["slug"]?.stringValue == model }),
              let efforts = info["supported_reasoning_levels"]?.arrayValue?.compactMap({ $0["effort"]?.stringValue }),
              !efforts.isEmpty, !efforts.contains(effort),
              let fallback = info["default_reasoning_level"] else { return }
        body["reasoning"]?["effort"] = fallback
    }

    /// Adds the jev-router row to a `GET /models` response, copied from a real model so every
    /// field Codex expects is present. Nil when there is nothing to add.
    ///
    /// The row doesn't prefer WebSockets: turns then use HTTP, where they are routed and the
    /// decision is shown. (A WebSocket `response.create` is routed too, as a fallback.)
    public func addingJevModel(_ catalog: JSONValue) -> JSONValue? {
        guard var models = catalog["models"]?.arrayValue,
              !models.contains(where: { $0["slug"]?.stringValue == RouterModel.id }) else { return nil }
        let balanced = CodexModel.id(for: .balanced, environment: environment)
        guard var entry = models.first(where: { $0["slug"]?.stringValue == balanced })
                ?? models.first(where: { $0["visibility"]?.stringValue == "list" })
                ?? models.first,
              case .object = entry else { return nil }
        entry["slug"] = .string(RouterModel.id)
        entry["display_name"] = "Dynamic (Jev)"
        entry["description"] = "Jev picks the cheapest model that can complete each turn."
        entry["visibility"] = "list"
        entry["supported_in_api"] = true
        entry["priority"] = 0
        entry["upgrade"] = .null
        if entry["prefer_websockets"] != nil { entry["prefer_websockets"] = false }
        models.insert(entry, at: 0)
        var result = catalog
        result["models"] = .array(models)
        return result
    }

    /// Requests signed in with ChatGPT (and the catalog) go to the ChatGPT backend; an API
    /// key goes to the public API.
    public static func usesChatGPT(path: String, accountHeader: String?) -> Bool {
        path.hasSuffix("/models") || !(accountHeader ?? "").isEmpty
    }

    // MARK: Decision display

    /// The decision as Responses API stream events: a commentary message Codex shows in the
    /// transcript, like its own progress notes.
    public static func decisionEvents(_ outcome: RoutingOutcome, id: String = "jev-\(UUID().uuidString.lowercased())") -> [JSONValue] {
        let detail = outcome.confidence.map { "\(outcome.reason), confidence \(String(format: "%.2f", $0))" } ?? outcome.reason
        let text = outcome.reason.hasPrefix("jev-unavailable")
            ? "[Jev] unavailable; using \(outcome.model). Run `jev setup` to configure a Jev host."
            : "[Jev] routed this turn to \(outcome.model) (\(detail))."
        let item: JSONValue = [
            "type": "message", "role": "assistant", "id": .string(id), "phase": "commentary",
            "content": [["type": "output_text", "text": .string(text)]],
        ]
        var added = item
        added["content"] = []
        return [
            ["type": "response.output_item.added", "item": added],
            ["type": "response.output_text.delta", "item_id": .string(id), "delta": .string(text)],
            ["type": "response.output_item.done", "item": item],
        ]
    }

    /// The events as SSE frames.
    public static func decisionFrames(_ outcome: RoutingOutcome) -> String {
        decisionEvents(outcome).map { event in
            "event: \(event["type"]?.stringValue ?? "")\ndata: \(event.serializedString())\n\n"
        }.joined()
    }
}
