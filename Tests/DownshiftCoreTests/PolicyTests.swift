import Testing
@testable import DownshiftCore

/// Port of `test/policy.test.mjs`. Node's haiku/sonnet/opus/fable are fast/balanced/strong/long.
struct PolicyTests {
    let all = Tier.allCases
    func sure(_ tier: Tier?) -> JevChoice { JevChoice(tier: tier, confidence: 0.95) }
    func unsure(_ tier: Tier?) -> JevChoice { JevChoice(tier: tier, confidence: 0.2) }

    func decide(prompt: String = "refactor the parser", jev: JevChoice?, current: Tier = .balanced,
                available: [Tier]? = nil, contextTokens: Int = 0) -> Decision {
        Policy.decide(prompt: prompt, jev: jev, current: current, available: available ?? all, contextTokens: contextTokens)
    }

    @Test func followsAConfidentJevAnswer() {
        #expect(decide(jev: sure(.strong)) == Decision(tier: .strong, reason: "jev", changed: true))
    }

    @Test func anExplicitUserOverrideBeatsJev() {
        let out = decide(prompt: "use haiku to fix this typo", jev: sure(.strong))
        #expect(out.tier == .fast)
        #expect(out.reason == "override")
    }

    @Test func detectOverrideOnlyFiresOnARealInstruction() {
        #expect(Policy.detectOverride("switch to opus") == .strong)
        #expect(Policy.detectOverride("use luna") == .fast)
        #expect(Policy.detectOverride("use strong") == .strong)
        #expect(Policy.detectOverride("the opus of his career") == nil)
        // Case-insensitive, any whitespace, and whole words only.
        #expect(Policy.detectOverride("Please SWITCH TO\tSonnet now") == .balanced)
        #expect(Policy.detectOverride("run with fable") == .long)
        #expect(Policy.detectOverride("use solid principles") == nil)
        #expect(Policy.detectOverride("reuse haiku") == nil)
        #expect(Policy.detectOverride("") == nil)
    }

    @Test func keepsTheCurrentModelWhenJevIsUnreachable() {
        let out = decide(jev: nil)
        #expect(out.tier == .balanced)
        #expect(!out.changed)
        #expect(out.reason == "jev-unavailable/no-change")
    }

    @Test func ignoresAModelJevInvented() {
        #expect(decide(jev: sure(nil)).tier == .balanced)
    }

    @Test func neverDowngradesOnALowConfidenceAnswer() {
        let out = decide(jev: unsure(.fast))
        #expect(out.tier == .balanced)
        #expect(out.reason.contains("low-confidence-no-downgrade"))
    }

    @Test func capsALowConfidenceUpgradeAtTheSafeCeiling() {
        let out = decide(jev: unsure(.long), current: .fast)
        #expect(out.tier == .balanced)
        #expect(out.reason == "low-confidence-capped")
    }

    @Test func lowConfidenceCeilingIsNeverBelowTheCurrentTier() {
        let out = decide(jev: unsure(.long), current: .strong)
        #expect(out.tier == .strong)
        #expect(out.reason == "low-confidence-capped/no-change")
    }

    @Test func stillAllowsAConfidentUpgradeToLong() {
        #expect(decide(jev: sure(.long)).tier == .long)
    }

    @Test func refusesADowngradeOnceTheCacheRebuildCostsMoreThanItSaves() {
        let out = decide(jev: sure(.fast), current: .strong, contextTokens: 80_000)
        #expect(out.tier == .strong)
        #expect(out.reason.contains("cache-rebuild"))
    }

    @Test func allowsTheSameDowngradeEarlyInAConversation() {
        #expect(decide(jev: sure(.fast), current: .strong).tier == .fast)
    }

    @Test func substitutesUpwardWhenTheChosenTierIsUnavailable() {
        let out = decide(jev: sure(.balanced), current: .fast, available: [.fast, .strong])
        #expect(out.tier == .strong)
        #expect(out.reason == "jev+unavailable")
    }

    @Test func neverSubstitutesUpwardIntoPaidLong() {
        let out = decide(jev: sure(.strong), current: .fast, available: [.fast, .long])
        #expect(out.tier == .fast)
    }

    @Test func fallsBackToTheCurrentTierWhenNothingIsAvailable() {
        let out = decide(jev: sure(.strong), current: .balanced, available: [])
        #expect(out == Decision(tier: .balanced, reason: "jev+unavailable/no-change", changed: false))
    }

    @Test func acceptsExactModelChangesWithinTheSameTier() {
        #expect(Policy.shouldUseExactModel(reason: "jev/no-change", chosen: .strong, final: .strong))
        #expect(!Policy.shouldUseExactModel(reason: "low-confidence-no-downgrade/no-change", chosen: .strong, final: .strong))
        #expect(!Policy.shouldUseExactModel(reason: "jev", chosen: .fast, final: .strong))
    }
}

struct TierTests {
    @Test func claudeFamilies() {
        #expect(ClaudeModel.tier(of: "claude-sonnet-4-6") == .balanced)
        #expect(ClaudeModel.tier(of: "opus") == .strong)
        #expect(ClaudeModel.tier(of: "sonnet[1m]") == .balanced)
        #expect(ClaudeModel.tier(of: "claude-fable-5-1") == .long)
        #expect(ClaudeModel.tier(of: "downshift") == nil)
        #expect(ClaudeModel.forTier(.fast).thinking == false)
    }

    @Test func codexModelsAndOverrides() {
        #expect(CodexModel.tier(of: "gpt-5.6-sol", environment: [:]) == .strong)
        #expect(CodexModel.tier(of: "gpt-6-astra", environment: [:]) == .long)
        #expect(CodexModel.tier(of: "gpt-5-mini", environment: [:]) == .fast)
        #expect(CodexModel.tier(of: "gpt-5", environment: [:]) == .balanced)
        #expect(CodexModel.tier(of: "o3", environment: [:]) == nil)

        let env = ["DSHIFT_CODEX_STRONG_MODEL": "gpt-7-custom"]
        #expect(CodexModel.id(for: .strong, environment: env) == "gpt-7-custom")
        #expect(CodexModel.tier(of: "gpt-7-custom", environment: env) == .strong)
        #expect(CodexModel.environmentKey(.fast) == "DSHIFT_CODEX_FAST_MODEL")
    }

    @Test func longTierIsOptIn() {
        #expect(Tier.available(allowLong: false) == [.fast, .balanced, .strong])
        #expect(Tier.available(allowLong: true) == Tier.allCases)
        #expect(DownshiftSettings(environment: .init(values: ["DSHIFT_ALLOW_FABLE": "1"])).availableTiers.contains(.long))
        #expect(!DownshiftSettings(environment: .init(values: ["DSHIFT_ALLOW_FABLE": "true"])).availableTiers.contains(.long))
    }
}
