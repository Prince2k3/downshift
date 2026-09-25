import Foundation
import JevCore

/// What the routing engine needs to know about one CLI's request format. Claude Code and
/// Codex differ in how a turn, a conversation and a catalog look, but not in how a turn is
/// routed, so `RoutingEngine` runs the same policy over either.
public protocol CLIAdapter: Sendable {
    /// The app's name in the usage ledger: `claude` or `codex`.
    var app: String { get }
    /// Fixes a request before anything else reads it (Claude's tool schemas).
    func prepare(_ body: inout JSONValue)
    /// The session id the body carries, or "".
    func sessionOf(_ body: JSONValue) -> String
    /// Identifies the conversation, so sub-agents keep their own routing state.
    func conversationKey(_ body: JSONValue) -> String
    /// The text of a genuinely new user turn, or nil for continuations and auxiliary calls.
    func newTurnPrompt(_ body: JSONValue) -> String?
    /// Whether the prompt asks jev to explain its last decision (never routed or recorded).
    func isExplainRequest(_ prompt: String) -> Bool
    /// Whether a request for a model the user picked is a real agent turn, which flips the
    /// status line to manual (auxiliary calls must not).
    func isAgentTurn(_ body: JSONValue) -> Bool
    func contextTokens(_ body: JSONValue) -> Int
    /// The model entries in a catalog response, or nil if it isn't one.
    func catalogEntries(_ body: JSONValue) -> [JSONValue]?
    /// The exact models to offer Jev, in catalog order, with a fallback per tier.
    func models(catalog: [JSONValue]) -> [RoutableModel]
    /// The first model in a tier, else the configured id for it.
    func model(for tier: Tier, in models: [RoutableModel]) -> String
    func tier(of model: String) -> Tier?
    /// Points the request at `model`, removing or clamping what that model can't accept.
    func apply(_ body: inout JSONValue, tier: Tier, model: String, catalog: [JSONValue])
}

/// Claude Code over the Messages API.
public struct ClaudeCLI: CLIAdapter {
    public init() {}

    public var app: String { "claude" }

    public func prepare(_ body: inout JSONValue) { ClaudeAdapter.sanitizeTools(&body) }
    public func sessionOf(_ body: JSONValue) -> String { ClaudeAdapter.sessionOf(body) }
    public func conversationKey(_ body: JSONValue) -> String { ClaudeAdapter.conversationKey(body) }
    public func newTurnPrompt(_ body: JSONValue) -> String? { ClaudeAdapter.newTurnPrompt(body) }
    public func isExplainRequest(_ prompt: String) -> Bool { ClaudeAdapter.isExplainRequest(prompt) }
    /// Auxiliary calls (titles, summaries) carry no tools.
    public func isAgentTurn(_ body: JSONValue) -> Bool { body["tools"]?.arrayValue != nil }
    public func contextTokens(_ body: JSONValue) -> Int { ClaudeAdapter.contextTokens(body) }

    public func catalogEntries(_ body: JSONValue) -> [JSONValue]? {
        guard let data = body["data"]?.arrayValue else { return nil }
        let entries = data.filter { $0["id"]?.stringValue.flatMap(ClaudeModel.tier(of:)) != nil }
        return entries.isEmpty ? nil : entries
    }

    public func models(catalog: [JSONValue]) -> [RoutableModel] { ClaudeAdapter.models(catalog: catalog) }
    public func model(for tier: Tier, in models: [RoutableModel]) -> String { ClaudeAdapter.model(for: tier, in: models) }
    public func tier(of model: String) -> Tier? { ClaudeModel.tier(of: model) }

    public func apply(_ body: inout JSONValue, tier: Tier, model: String, catalog: [JSONValue]) {
        ClaudeAdapter.applyTier(&body, tier: tier, model: model)
    }
}
