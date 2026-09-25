/// Every routing threshold, so the whole policy can be reviewed in one place. The values are
/// the same on every Jev host: the questions and answer semantics don't change between them.
public enum Thresholds {
    /// Below this Jev confidence, never downgrade and cap upgrades at `uncertainCeiling`.
    public static let minConfidence = 0.3
    /// The safest tier to land on when Jev is unsure.
    public static let uncertainCeiling = Tier.balanced
    /// Switching models invalidates the prompt cache and the next turn re-sends the whole
    /// conversation (measured at about 23.6k cache-creation tokens switching into Opus), so a
    /// downgrade only pays off while the conversation is still small.
    public static let downgradeMaxContextTokens = 20_000
    /// Per-attempt Jev timeout and the wall-clock deadline for the whole routing call.
    /// Measured at about 300–350 ms warm and 900–1000 ms cold (TLS handshake), so the deadline
    /// leaves room for one retry after a cold-start timeout.
    public static let jevTimeout: Duration = .milliseconds(1500)
    public static let jevDeadline: Duration = .milliseconds(3000)
    public static let jevMaxRetries = 1
    /// Denominator for the context-size metric shown by `jev explain`.
    public static let contextWindowTokens = 200_000
}

/// What Jev answered for the model question, as far as the policy is concerned.
public struct JevChoice: Sendable, Hashable {
    /// The tier of the model Jev chose; nil when it chose something that maps to no tier.
    public var tier: Tier?
    public var confidence: Double

    public init(tier: Tier?, confidence: Double) {
        self.tier = tier
        self.confidence = confidence
    }
}

public struct Decision: Sendable, Hashable {
    public var tier: Tier
    /// Why, e.g. `jev`, `override`, `low-confidence-capped`, `jev-unavailable/no-change`.
    /// `+unavailable` is appended when the tier was clamped to one the account can run, and
    /// `/no-change` when the result is the tier already in use.
    public var reason: String
    public var changed: Bool

    public init(tier: Tier, reason: String, changed: Bool) {
        self.tier = tier
        self.reason = reason
        self.changed = changed
    }
}

/// Turns a Jev answer into the tier that will actually run. Pure and total: missing,
/// malformed or unavailable input falls back to the tier already in use.
public enum Policy {
    /// The tier the user named in the prompt ("use opus", "switch to sol"), or nil.
    public static func detectOverride(_ prompt: String) -> Tier? {
        Tier.allCases.first { tier in
            prompt.firstMatch(of: overridePatterns[tier.rank]) != nil
        }
    }

    // `\b(?:use|switch to|with|on)\s+(?:haiku|fast|luna)\b`, case-insensitive, with the
    // simple (ASCII-style) word boundaries JavaScript uses.
    nonisolated(unsafe) private static let overridePatterns: [Regex<Substring>] = Tier.allCases.map { tier in
        let words = tier.overrideWords.joined(separator: "|")
        return try! Regex(#"\b(?:use|switch to|with|on)\s+(?:"# + words + #")\b"#)
            .ignoresCase()
            .wordBoundaryKind(.simple)
    }

    /// - Parameters:
    ///   - prompt: the raw user prompt, checked for an explicit override.
    ///   - jev: Jev's answer, or nil when the call failed.
    ///   - current: the tier currently active in the conversation.
    ///   - available: the tiers the account can run.
    ///   - contextTokens: the approximate size of the conversation so far.
    public static func decide(prompt: String, jev: JevChoice?, current: Tier, available: [Tier],
                              contextTokens: Int = 0) -> Decision {
        func settle(_ tier: Tier, _ reason: String) -> Decision {
            let final = clamp(tier, to: available) ?? current
            let why = final == tier ? reason : "\(reason)+unavailable"
            return Decision(tier: final, reason: final == current ? "\(why)/no-change" : why, changed: final != current)
        }

        if let override = detectOverride(prompt) { return settle(override, "override") }

        guard let jev, let target = jev.tier else { return settle(current, "jev-unavailable") }

        if jev.confidence < Thresholds.minConfidence {
            if target < current { return settle(current, "low-confidence-no-downgrade") }
            let ceiling = max(current, Thresholds.uncertainCeiling)
            if target > ceiling { return settle(ceiling, "low-confidence-capped") }
        }

        if target < current && contextTokens > Thresholds.downgradeMaxContextTokens {
            return settle(current, "downgrade-not-worth-cache-rebuild")
        }

        return settle(target, "jev")
    }

    /// The nearest tier the account can run. Steps up rather than down, so a hard task is
    /// never silently handed to a weaker model, but never steps up into `long` (which bills
    /// extra) unless `long` is what was asked for.
    static func clamp(_ tier: Tier, to available: [Tier]) -> Tier? {
        if available.contains(tier) { return tier }
        if let up = Tier.allCases.first(where: { $0 > tier && available.contains($0) && ($0 != .long || tier == .long) }) {
            return up
        }
        return Tier.allCases.last { $0 < tier && available.contains($0) }
    }

    /// Whether the policy accepted Jev's exact model, including a version change within one
    /// tier, rather than only its tier.
    public static func shouldUseExactModel(reason: String, chosen: Tier?, final: Tier) -> Bool {
        (reason == "jev" || reason == "jev/no-change") && chosen == final
    }
}
