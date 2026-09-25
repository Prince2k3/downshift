import Foundation
import DownshiftCore

/// What the router asks Jev for one new turn.
public struct RouteRequest: Sendable {
    public var prompt: String
    /// The exact model the conversation is on now.
    public var current: String
    public var contextTokens: Int
    public var models: [RoutableModel]

    public init(prompt: String, current: String, contextTokens: Int, models: [RoutableModel]) {
        self.prompt = prompt
        self.current = current
        self.contextTokens = contextTokens
        self.models = models
    }
}

/// Jev's answer to the model question.
public struct RouteAnswer: Sendable {
    /// The exact model id Jev chose (one of `RouteRequest.models`).
    public var choice: String
    public var confidence: Double
    /// Jev's reply, for the tokens its own call used.
    public var response: JSONValue?

    public init(choice: String, confidence: Double, response: JSONValue? = nil) {
        self.choice = choice
        self.confidence = confidence
        self.response = response
    }
}

/// Asks Jev. Nil means the call failed or timed out, and routing fails open.
public typealias JevRouter = @Sendable (RouteRequest) async -> RouteAnswer?

/// One routing decision, for showing it to the user in the response (Codex).
public struct RoutingOutcome: Sendable, Equatable {
    public var tier: Tier
    public var model: String
    public var confidence: Double?
    public var reason: String

    public init(tier: Tier, model: String, confidence: Double?, reason: String) {
        self.tier = tier
        self.model = model
        self.confidence = confidence
        self.reason = reason
    }
}

/// Owns per-conversation routing state and the account's model catalog, and turns a routed
/// request into the concrete model to send. One engine serves one CLI, described by its
/// adapter (Claude Code or Codex). The Jev call happens outside the actor,
/// so one slow routing call never blocks other conversations.
public actor RoutingEngine {
    /// Conversations remembered at once; the least recently used is forgotten first.
    public static let conversationLimit = 50

    struct Conversation {
        var tier: Tier?
        var model: String?
    }

    public nonisolated let adapter: any CLIAdapter
    public nonisolated let baseline: Tier
    /// The exact model new conversations start on, when the user configured one (Codex's
    /// `model` in config.toml); used only while the catalog offers it.
    public nonisolated let baselineModel: String?
    public nonisolated let available: [Tier]
    nonisolated let router: JevRouter?
    nonisolated let store: StatusStore?
    nonisolated let log: DownshiftLog?
    nonisolated let ledger: UsageLedger?
    nonisolated let now: @Sendable () -> Date

    var conversations: [String: Conversation] = [:]
    /// Least recently used first.
    var order: [String] = []
    var catalog: [JSONValue] = []

    /// - Parameters:
    ///   - adapter: the CLI's request format; Claude Code unless given.
    ///   - baseline: the tier every new conversation starts on, i.e. the model the user would
    ///     have been on without dshift (plan §5a).
    ///   - baselineModel: the exact model for the baseline, if the user named one.
    ///   - available: the tiers the account may be routed to.
    ///   - router: asks Jev; nil keeps every conversation on its current tier.
    ///   - store: where decisions are published for the status line; nil publishes nothing.
    ///   - ledger: where each turn's tokens (and Jev's own) are recorded; nil records nothing.
    public init(adapter: any CLIAdapter = ClaudeCLI(), baseline: Tier, baselineModel: String? = nil,
                available: [Tier], router: JevRouter?, store: StatusStore?,
                log: DownshiftLog? = nil, ledger: UsageLedger? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.adapter = adapter
        self.baseline = baseline
        self.baselineModel = baselineModel
        self.available = available
        self.router = router
        self.store = store
        self.log = log
        self.ledger = ledger
        self.now = now
    }

    // MARK: Catalog

    /// Records the models in a catalog response body. Anything unparseable is ignored; the
    /// configured ids remain the fallback.
    public func observeCatalog(_ body: JSONValue) {
        guard let entries = adapter.catalogEntries(body) else { return }
        catalog = entries
    }

    public func models() -> [RoutableModel] {
        adapter.models(catalog: catalog).filter { available.contains($0.tier) }
    }

    func catalogEntries() -> [JSONValue] { catalog }

    /// Where a new conversation starts: the user's own model if the catalog offers it, else
    /// the first model in the baseline tier.
    nonisolated func start(in models: [RoutableModel]) -> (tier: Tier, model: String) {
        if let baselineModel, let model = models.first(where: { $0.id == baselineModel }) {
            return (model.tier, model.id)
        }
        return (baseline, adapter.model(for: baseline, in: models))
    }

    // MARK: Conversations

    func conversation(_ key: String) -> Conversation {
        if let state = conversations[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return state
        }
        if conversations.count >= Self.conversationLimit, let oldest = order.first {
            order.removeFirst()
            conversations[oldest] = nil
        }
        let state = Conversation()
        conversations[key] = state
        order.append(key)
        return state
    }

    func update(_ key: String, tier: Tier, model: String) {
        guard conversations[key] != nil else { return }
        conversations[key] = Conversation(tier: tier, model: model)
    }

    var conversationCount: Int { conversations.count }

    // MARK: Requests

    /// Rewrites one request body in place and returns the decision, if this request made one. A model other than the sentinel is the
    /// user's own choice and passes through untouched (and flips the status line to manual).
    /// - Parameters:
    ///   - headerSession: the session header (`x-claude-code-session-id`, Codex's
    ///     `session-id`), which the apps send even when the body carries no session.
    ///   - decide: false only rewrites the model for the conversation's current tier, without
    ///     asking Jev or publishing anything (token counting).
    @discardableResult
    public nonisolated func process(_ body: inout JSONValue, headerSession: String? = nil, decide: Bool = true) async -> RoutingOutcome? {
        await route(&body, headerSession: headerSession, decide: decide).outcome
    }

    /// `process`, plus where to record the tokens the response reports (nil when `decide` is
    /// false or there is no ledger).
    public nonisolated func route(_ body: inout JSONValue, headerSession: String? = nil,
                                  decide: Bool = true) async -> (outcome: RoutingOutcome?, usage: UsageContext?) {
        adapter.prepare(&body)
        let bodySession = adapter.sessionOf(body)
        let session = bodySession.isEmpty ? (headerSession ?? "") : bodySession
        func usage(baseline: String?, routed: Bool) -> UsageContext? {
            guard decide, let ledger else { return nil }
            return UsageContext(ledger: ledger, app: adapter.app, session: session, baseline: baseline, routed: routed, now: now)
        }

        guard RouterModel.isRouted(body["model"]?.stringValue) else {
            guard decide else { return (nil, nil) }
            // Only a real agent turn reflects the user's choice; auxiliary calls (titles,
            // summaries) must not flip the status line to manual mid-session.
            if adapter.isAgentTurn(body), !session.isEmpty {
                store?.write(["manual": true, "at": .number(milliseconds())], session: session)
            }
            // The user's own pick is its own baseline: it counts, but saves nothing.
            return (nil, usage(baseline: nil, routed: false))
        }

        let key = adapter.conversationKey(body)
        let state = await conversation(key)
        let models = await models()
        let start = start(in: models)
        // What the prompt cache was built on, which is what a downgrade would discard.
        let current = state.tier ?? start.tier
        let currentModel = state.model ?? start.model
        var tier = current
        var model = currentModel
        var outcome: RoutingOutcome?

        let prompt = adapter.newTurnPrompt(body)
        if decide, let prompt {
            let contextTokens = adapter.contextTokens(body)
            let answer = await router?(RouteRequest(prompt: prompt, current: currentModel,
                                                    contextTokens: contextTokens, models: models))
            if let answer { recordJevUsage(answer, session: session) }
            let chosen = answer.flatMap { answer in models.first { $0.id == answer.choice } }
            let decision = Policy.decide(
                prompt: prompt,
                jev: answer.map { JevChoice(tier: chosen?.tier, confidence: $0.confidence) },
                current: current,
                available: Array(Set(models.map(\.tier))).sorted(),
                contextTokens: contextTokens)
            tier = decision.tier
            if let chosen, Policy.shouldUseExactModel(reason: decision.reason, chosen: chosen.tier, final: decision.tier) {
                model = chosen.id
            } else {
                model = decision.tier == current ? currentModel : adapter.model(for: decision.tier, in: models)
            }
            await update(key, tier: tier, model: model)
            outcome = RoutingOutcome(tier: tier, model: model, confidence: answer?.confidence, reason: decision.reason)

            log?.debug("\(key) \(answer.map { String(format: "p=%.2f", $0.confidence) } ?? "no-jev") "
                       + "\(current.rawValue) -> \(tier.rawValue) (\(decision.reason)) ctx~\(contextTokens)")

            // `claude -p` omits metadata on a session's first request, so without a session
            // id the decision is filed under the conversation key instead of being dropped.
            store?.write([
                "tier": .string(tier.rawValue),
                "model": .string(model),
                "confidence": answer.map { .number($0.confidence) } ?? .null,
                "reason": .string(decision.reason),
                "at": .number(milliseconds()),
            ], session: session.isEmpty ? key : session)
        }

        // The sentinel is not a real model, so every routed request is rewritten, including
        // the follow-ups that reuse the tier chosen at the start of the turn.
        adapter.apply(&body, tier: tier, model: model, catalog: await catalogEntries())
        return (outcome, usage(baseline: start.model, routed: true))
    }

    /// Records the tokens Jev's own routing call used, which count against what it saved.
    nonisolated func recordJevUsage(_ answer: RouteAnswer, session: String) {
        guard let ledger, let response = answer.response, let usage = response["usage"] else { return }
        let tokens = TokenUsage(input: usage["input_tokens"]?.intValue ?? 0, output: usage["output_tokens"]?.intValue ?? 0)
        guard !tokens.isEmpty else { return }
        ledger.append(UsageRecord(at: now(), kind: .jev, app: adapter.app, session: session,
                                  model: response["model"]?.stringValue ?? "jev", baseline: nil, routed: true, tokens: tokens))
    }

    nonisolated func milliseconds() -> Int { Int(now().timeIntervalSince1970 * 1000) }
}
