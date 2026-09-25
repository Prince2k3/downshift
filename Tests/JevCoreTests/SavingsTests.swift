import Foundation
import Testing
@testable import JevCore

@Suite struct PriceTableTests {
    @Test func normalizesProviderPrefixesDatesAndContextSuffixes() {
        #expect(PriceTable.normalize("Anthropic/Claude-Opus-4-8[1m]") == "claude-opus-4-8")
        #expect(PriceTable.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(PriceTable.normalize("openai/gpt-5-2025-08-07") == "gpt-5")
        #expect(PriceTable.normalize("claude-3-5-haiku-latest") == "claude-3-5-haiku")
        #expect(PriceTable.normalize("~typesafe/jev-latest") == "jev")
        #expect(PriceTable.normalize("gpt-5.6-terra") == "gpt-5.6-terra")
    }

    @Test func pricesTheModelsJevRoutesBetween() throws {
        let table = PriceTable()
        for id in ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5", "claude-fable-5-1",
                   "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-astra", "gpt-6-luna", "gpt-6-sol"] {
            #expect(table.price(for: id) != nil, "\(id)")
        }
        let opus = try #require(table.price(for: "claude-opus-5"))
        #expect(opus == ModelPrice(input: 5, cacheWrite: 6.25, cacheRead: 0.5, output: 25))
        #expect(opus.cost(TokenUsage(input: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)) == 36.75)
        // Jev's price covers every host's model id; output is free.
        for id in ["typesafe/jev", "jev-latest", "typesafe-ai/jev", "~typesafe/jev-latest"] {
            #expect(table.cost(TokenUsage(input: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000, output: 1_000_000), model: id) == 0.042, "\(id)")
        }
        // Unknown models are unpriced rather than free.
        #expect(table.cost(TokenUsage(input: 1), model: "mystery-model") == nil)
    }

    @Test func overridesMergeAndMissingCacheRatesUseTheInputRate() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("jev-prices-\(UUID().uuidString)")
        let file = home.appendingPathComponent(".config/jev/prices.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"models": {"Jev-Latest": {"input": 1, "output": 4}, "claude-sonnet-5": {"input": 3, "output": 15, "cache_read": 0.3}}}"#.utf8)
            .write(to: file)

        let loaded = PriceTable.load(environment: ["HOME": home.path])
        #expect(loaded.file == file)
        #expect(loaded.problem == nil)
        #expect(loaded.table.overridden == ["jev", "claude-sonnet-5"])
        #expect(loaded.table.price(for: "jev-latest") == ModelPrice(input: 1, cacheWrite: 1, cacheRead: 1, output: 4))
        #expect(loaded.table.price(for: "claude-sonnet-5") == ModelPrice(input: 3, cacheWrite: 3, cacheRead: 0.3, output: 15))
        #expect(loaded.table.price(for: "claude-opus-5") == PriceTable.builtIn["claude-opus-5"])

        let xdg = PriceTable.load(environment: ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent("elsewhere").path])
        #expect(xdg.table.price(for: "jev-latest") == PriceTable.builtIn["jev"])

        try Data(#"{"models": {"x": {"output": 4}}}"#.utf8).write(to: file)
        let bad = PriceTable.load(environment: ["HOME": home.path])
        #expect(bad.problem?.contains("missing \"input\"") == true)
        #expect(bad.table.price(for: "claude-opus-5") != nil)
    }
}

@Suite struct SavingsReportTests {
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    static func turn(_ model: String, baseline: String?, routed: Bool, session: String, app: String = "claude",
                     _ tokens: TokenUsage) -> UsageRecord {
        UsageRecord(at: at, kind: .turn, app: app, session: session, model: model, baseline: baseline, routed: routed, tokens: tokens)
    }

    static let records: [UsageRecord] = [
        // Sonnet 5 instead of Opus 5: $0.20 + $0.20 + $0.10 = $0.50 against $0.50 + $0.50 + $0.25 = $1.25.
        turn("claude-sonnet-5", baseline: "claude-opus-5", routed: true, session: "s1",
             TokenUsage(input: 100_000, cacheRead: 1_000_000, output: 10_000)),
        // The user's own pick: $1.00 either way.
        turn("claude-opus-5", baseline: nil, routed: false, session: "s1", TokenUsage(input: 200_000)),
        UsageRecord(at: at, kind: .jev, app: "claude", session: "s1", model: "jev-latest", baseline: nil, routed: true,
                    tokens: TokenUsage(input: 1000, output: 100)),
        turn("mystery-model", baseline: "claude-opus-5", routed: true, session: "s2", TokenUsage(input: 5)),
        // Luna instead of Sol: $0.10 + $0.50 = $0.60 against $2 + $10 = $12.
        turn("gpt-6-luna", baseline: "gpt-6-sol", routed: true, session: "c1", app: "codex",
             TokenUsage(input: 1_000_000, output: 1_000_000)),
    ]

    @Test func matchesTheHandComputedFigures() {
        let prices = PriceTable(overrides: ["jev-latest": ModelPrice(input: 1, output: 4)])
        let claude = SavingsReport(records: Self.records, prices: prices, app: "claude")
        #expect(claude.turns == 3)
        #expect(claude.routedTurns == 2 && claude.manualTurns == 1)
        #expect(abs(claude.actualCost - 1.5) < 1e-9)
        #expect(abs(claude.baselineCost - 2.25) < 1e-9)
        #expect(abs(claude.jevCost - 0.0014) < 1e-9)
        #expect(abs(claude.savings - 0.7486) < 1e-9)
        #expect(claude.unpricedTurns == 1)
        #expect(claude.unpricedModels == ["mystery-model"])
        // s1: one manual turn of two; s2: none of one.
        #expect(claude.sessionsRouted == 2)
        #expect(claude.overrideRate == 1.0 / 3.0)
        #expect(claude.models.map(\.model) == ["claude-opus-5", "claude-sonnet-5", "mystery-model"])
        #expect(claude.models.last?.cost == nil)

        let all = SavingsReport(records: Self.records, prices: prices)
        #expect(abs(all.actualCost - 2.1) < 1e-9)
        #expect(abs(all.baselineCost - 14.25) < 1e-9)
    }

    @Test func jevCallsUseTheBuiltInJevPrice() {
        let report = SavingsReport(records: Self.records, prices: PriceTable(), app: "claude")
        // 1,000 input tokens at $0.042 per million; the 100 output tokens are free.
        #expect(report.jevCalls == 1 && report.unpricedJevCalls == 0)
        #expect(abs(report.jevCost - 0.000042) < 1e-12)
        #expect(report.unpricedModels == ["mystery-model"])
        #expect(report.summary.hasSuffix(", some unpriced"))
    }

    @Test func baselineOptionRepricesOnlyRoutedTurns() {
        let report = SavingsReport(records: Self.records, prices: PriceTable(), baseline: "claude-sonnet-5")
        // Sonnet turn saves nothing, the manual turn stays $1.00, Luna is priced against Sonnet 5 ($12).
        #expect(abs(report.baselineCost - 13.5) < 1e-9)
        #expect(abs(report.actualCost - 2.1) < 1e-9)
    }

    @Test func sinceAcceptsDurationsAllAndDates() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SincePeriod.parse("7d", now: now) == .some(now.addingTimeInterval(-7 * 86_400)))
        #expect(SincePeriod.parse("24h", now: now) == .some(now.addingTimeInterval(-86_400)))
        #expect(SincePeriod.parse("2w", now: now) == .some(now.addingTimeInterval(-14 * 86_400)))
        #expect(SincePeriod.parse("all", now: now) == .some(nil))
        #expect(SincePeriod.parse("2026-09-01", now: now) == .some(ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")))
        #expect(SincePeriod.parse("soon", now: now) == nil)
        #expect(SincePeriod.parse("0d", now: now) == nil)
    }

    @Test func formatsSmallAmountsVisibly() {
        #expect(SavingsReport.dollars(12.345) == "$12.35")
        #expect(SavingsReport.dollars(0.0042) == "$0.0042")
        #expect(SavingsReport.dollars(-0.5) == "-$0.50")
        #expect(SavingsReport.dollars(0) == "$0.00")
        #expect(SavingsReport.count(1_234_567) == "1.2M")
        #expect(SavingsReport.count(45_000) == "45k")
    }
}
