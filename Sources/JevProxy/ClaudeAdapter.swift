import Crypto
import Foundation
import JevCore

/// One exact model the account can run, offered to Jev as a choice.
public struct RoutableModel: Sendable, Hashable {
    public var id: String
    public var tier: Tier
    public var description: String

    public init(id: String, tier: Tier, description: String) {
        self.id = id
        self.tier = tier
        self.description = description
    }
}

/// What the Claude Messages API request looks like to the router: pure functions over the
/// parsed body, so every rule can be tested without a server.
public enum ClaudeAdapter {
    public static let sessionHeader = "x-claude-code-session-id"

    /// Claude Code converts draft-04 relics in MCP tool schemas before sending them
    /// first-party, but skips that when `ANTHROPIC_BASE_URL` is set, so the API rejects the
    /// request. In draft 2020-12 `exclusiveMinimum`/`exclusiveMaximum` are numbers, not booleans.
    public static func sanitizeSchema(_ node: inout JSONValue) {
        switch node {
        case .array(var items):
            for index in items.indices { sanitizeSchema(&items[index]) }
            node = .array(items)
        case .object(var object):
            for (key, bound) in [("exclusiveMinimum", "minimum"), ("exclusiveMaximum", "maximum")] {
                guard case .bool(let exclusive)? = object[key] else { continue }
                if exclusive, case .number? = object[bound] {
                    object[key] = object[bound]
                    object[bound] = nil
                } else {
                    object[key] = nil
                }
            }
            for index in object.entries.indices { sanitizeSchema(&object.entries[index].value) }
            node = .object(object)
        default:
            return
        }
    }

    /// Sanitizes every tool's `input_schema` in a request body.
    public static func sanitizeTools(_ body: inout JSONValue) {
        guard case .array(var tools)? = body["tools"] else { return }
        for index in tools.indices {
            guard var schema = tools[index]["input_schema"] else { continue }
            sanitizeSchema(&schema)
            tools[index]["input_schema"] = schema
        }
        body["tools"] = .array(tools)
    }

    nonisolated(unsafe) private static let systemReminder = try! Regex(#"<system-reminder>[\s\S]*?</system-reminder>"#)

    /// The text of a genuinely new user turn, or nil.
    ///
    /// A turn continues for many requests while Claude works through tool calls, and those
    /// continuations end in a `tool_result` rather than typed text. Routing them would re-ask
    /// Jev on every tool call and let the model flip mid-task, so only the opening request of
    /// a turn counts. Auxiliary calls (titles, summaries) carry no tools and are skipped.
    /// `<system-reminder>` blocks are noise to a router and blunt Jev's confidence.
    public static func newTurnPrompt(_ body: JSONValue) -> String? {
        guard let tools = body["tools"]?.arrayValue, !tools.isEmpty,
              let last = body["messages"]?.arrayValue?.last, last["role"]?.stringValue == "user" else { return nil }
        let text: String
        switch last["content"] {
        case .string(let string)?:
            text = string
        case .array(let blocks)?:
            if blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) { return nil }
            text = blocks.filter { $0["type"]?.stringValue == "text" }
                .map { $0["text"]?.stringValue ?? "" }
                .joined(separator: "\n")
        default:
            return nil
        }
        let prompt = text.replacing(systemReminder, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    /// Whether the prompt is the `/jev-explain` skill asking about the last decision, which
    /// must not itself be routed or recorded.
    public static func isExplainRequest(_ prompt: String) -> Bool { prompt.contains("<jev-explain>") }

    /// Points a request at a tier's model, removing fields that tier cannot accept. Claude
    /// Code composes the body for the model it thinks it is talking to, so routing down to
    /// Haiku while leaving `thinking: {type: "adaptive"}` in place is a hard 400.
    public static func applyTier(_ body: inout JSONValue, tier: Tier, model: String? = nil) {
        let spec = ClaudeModel.forTier(tier)
        body["model"] = .string(model ?? spec.id)
        if !spec.thinking {
            body["thinking"] = nil
            // A strategy that prunes thinking blocks is itself rejected once thinking is gone.
            if case .array(let edits)? = body["context_management"]?["edits"] {
                let kept = edits.filter { edit in
                    !(edit["type"]?.stringValue ?? "").localizedCaseInsensitiveContains("thinking")
                }
                body["context_management"]?["edits"] = .array(kept)
                if kept.isEmpty { body["context_management"] = nil }
            }
        }
        if !spec.effort, case .object(var config)? = body["output_config"] {
            config["effort"] = nil
            body["output_config"] = config.isEmpty ? nil : .object(config)
        }
    }

    /// Exact Claude models from the account's `/v1/models` catalog, in catalog order (newest
    /// first). Before the catalog arrives, one static id per tier is the cold-start fallback.
    public static func models(catalog: [JSONValue]) -> [RoutableModel] {
        let models = catalog.compactMap { entry -> RoutableModel? in
            guard let id = entry["id"]?.stringValue, let tier = ClaudeModel.tier(of: id) else { return nil }
            let description = [
                entry["display_name"]?.stringValue,
                entry["created_at"]?.stringValue.map { "released \($0.prefix(10))" },
                entry["max_input_tokens"]?.intValue.map { "\($0) input tokens" },
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
            return RoutableModel(id: id, tier: tier, description: description)
        }
        return models.isEmpty ? ClaudeModel.all.map { RoutableModel(id: $0.id, tier: $0.tier, description: $0.id) } : models
    }

    /// The first catalog model in a tier, else the static id for it.
    public static func model(for tier: Tier, in models: [RoutableModel]) -> String {
        models.first { $0.tier == tier }?.id ?? ClaudeModel.forTier(tier).id
    }

    /// The session id Claude Code embeds in `metadata.user_id` (itself a JSON string), or "".
    public static func sessionOf(_ body: JSONValue) -> String {
        guard let userID = body["metadata"]?["user_id"]?.stringValue,
              let parsed = try? JSONValue.parse(userID) else { return "" }
        return parsed["session_id"]?.stringValue ?? ""
    }

    /// Identifies the conversation a request belongs to. Claude Code runs sub-agents through
    /// the same endpoint, so one pinned model per session would leak a sub-agent's choice into
    /// the main conversation. Only stable fields are used: the session id and the text of the
    /// first message, which is fixed once a conversation starts (Claude Code moves its
    /// `cache_control` breakpoint between requests, so whole blocks can't be hashed).
    public static func conversationKey(_ body: JSONValue) -> String {
        let text: String
        switch body["messages"]?[0]?["content"] {
        case .string(let string)?:
            text = string
        case .array(let blocks)?:
            text = blocks.filter { $0["type"]?.stringValue == "text" }.map { $0["text"]?.stringValue ?? "" }.joined()
        default:
            text = ""
        }
        let digest = Insecure.SHA1.hash(data: Data("\(sessionOf(body))|\(text)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// Rough size of the conversation so far, as Node measured it: a quarter of the length of
    /// the serialized messages.
    public static func contextTokens(_ body: JSONValue) -> Int {
        let length = (body["messages"] ?? .null).serializedString().utf16.count
        return Int((Double(length) / 4).rounded())
    }
}
