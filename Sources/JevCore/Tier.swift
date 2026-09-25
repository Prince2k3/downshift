/// Capability tiers, cheapest first. Each CLI maps its own model families onto these
/// (Claude: haiku/sonnet/opus/fable; Codex: luna/terra/sol/astra).
public enum Tier: String, Sendable, CaseIterable, Comparable, Codable {
    case fast
    case balanced
    case strong
    case long

    public var rank: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rank < rhs.rank }

    /// Words that name this tier in a prompt override ("use opus", "switch to sol").
    /// The Claude family comes first because it is the tier's display name for Claude users.
    public var overrideWords: [String] {
        switch self {
        case .fast: ["haiku", "fast", "luna"]
        case .balanced: ["sonnet", "balanced", "terra"]
        case .strong: ["opus", "strong", "sol"]
        case .long: ["fable", "long", "astra"]
        }
    }

    /// Tiers the account may be routed to. `long` bills extra usage credits (Fable on Claude,
    /// Astra on Codex), so it is opt-in with `JEV_ALLOW_FABLE=1`.
    public static func available(allowLong: Bool) -> [Tier] {
        allCases.filter { $0 != .long || allowLong }
    }
}

/// One Claude model family. `id` is what goes into the request body; `family` is the
/// substring that recognises whatever model Claude Code asked for, which may be an older
/// version within the tier (`claude-sonnet-4-6`). Haiku accepts neither adaptive thinking
/// nor effort, so those fields are stripped when routing down to it.
public struct ClaudeModel: Sendable, Hashable {
    public var tier: Tier
    public var id: String
    public var family: String
    public var thinking: Bool
    public var effort: Bool

    public static let all: [ClaudeModel] = [
        ClaudeModel(tier: .fast, id: "claude-haiku-4-5-20251001", family: "haiku", thinking: false, effort: false),
        ClaudeModel(tier: .balanced, id: "claude-sonnet-5", family: "sonnet", thinking: true, effort: true),
        ClaudeModel(tier: .strong, id: "claude-opus-5", family: "opus", thinking: true, effort: true),
        ClaudeModel(tier: .long, id: "claude-fable-5-1", family: "fable", thinking: true, effort: true),
    ]

    public static func forTier(_ tier: Tier) -> ClaudeModel { all.first { $0.tier == tier }! }

    /// The tier of a model id or alias Claude Code sent (`opus`, `sonnet[1m]`,
    /// `claude-opus-4-6`), or nil if it names no known family.
    public static func tier(of model: String) -> Tier? {
        all.first { model.contains($0.family) }?.tier
    }
}

/// The sentinel model id offered as an extra row in the Claude and Codex model pickers. Its
/// presence in a request is the exact signal that the user wants this turn routed; any other
/// model is the user's own choice and passes straight through.
public enum RouterModel {
    public static let id = "jev-router"
    public static func isRouted(_ model: String?) -> Bool { model == id }
}

/// Codex model ids per tier. Each can be replaced with `JEV_CODEX_<TIER>_MODEL`.
public enum CodexModel {
    public static let defaults: [Tier: String] = [
        .fast: "gpt-5.6-luna",
        .balanced: "gpt-5.6-terra",
        .strong: "gpt-5.6-sol",
        .long: "gpt-6-astra",
    ]

    public static func environmentKey(_ tier: Tier) -> String {
        "JEV_CODEX_\(tier.rawValue.uppercased())_MODEL"
    }

    public static func id(for tier: Tier, environment: [String: String]) -> String {
        environment[environmentKey(tier)] ?? defaults[tier]!
    }

    /// The tier of a Codex model slug: a configured id first, then by name, then any other
    /// `gpt-*` model is treated as balanced. Nil for anything that isn't a GPT model.
    public static func tier(of model: String, environment: [String: String]) -> Tier? {
        if let configured = Tier.allCases.first(where: { id(for: $0, environment: environment) == model }) {
            return configured
        }
        let lower = model.lowercased()
        if ["astra", "fable", "long"].contains(where: lower.contains) { return .long }
        if ["sol", "opus", "strong", "max", "pro"].contains(where: lower.contains) { return .strong }
        if ["luna", "haiku", "fast", "mini", "nano"].contains(where: lower.contains) { return .fast }
        return lower.hasPrefix("gpt-") ? .balanced : nil
    }
}
