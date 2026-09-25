import ArgumentParser
import Foundation
import DownshiftCore

struct SavingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "savings",
        abstract: "Estimate what routing saved: each turn at the model that answered vs. the model it started on.",
        discussion: """
            Prices come from the providers' list prices (built in, dated) plus \
            ~/.config/downshift/prices.json, e.g. {"models": {"my-model": {"input": 1, "output": 4}}}. \
            Missing cache_read / cache_write rates are charged at the input rate. Models without a \
            price are reported as unpriced and left out of both totals.
            """)

    @Option(help: "How far back: 7d, 24h, 2w, all, or a date (2026-09-01).") var since = "30d"
    @Option(help: "Price routed turns against this model instead of the one each conversation started on.") var baseline: String?
    @Option(help: "Only claude or codex.") var app: String?
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        guard SincePeriod.parse(since) != nil else { throw ValidationError("--since takes 7d, 24h, 2w, all, or a date like 2026-09-01") }
        if let app, !["claude", "codex"].contains(app) { throw ValidationError("--app takes claude or codex") }
    }

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let start = SincePeriod.parse(since) ?? nil
        let records = UsageLedger.standard(environment: environment).records(since: start)
        let pricing = PriceTable.load(environment: environment)
        if let problem = pricing.problem { FileHandle.standardError.write(Data("dshift: \(problem)\n".utf8)) }
        let report = SavingsReport(records: records, prices: pricing.table, baseline: baseline, app: app)
        let baselines = baseline.map { [$0] }
            ?? Array(Set(records.filter { $0.kind == .turn && $0.routed && (app == nil || $0.app == app) }.compactMap(\.baseline))).sorted()

        if json {
            Swift.print(String(decoding: Self.json(report, since: start, baselines: baselines, pricing: pricing).serialized(indent: 2), as: UTF8.self))
        } else {
            Self.report(report, since: start, period: since, baselines: baselines, pricing: pricing)
        }
    }

    static func report(_ report: SavingsReport, since: Date?, period: String, baselines: [String],
                      pricing: (table: PriceTable, file: URL, problem: String?)) {
        func line(_ label: String, _ value: String) { Swift.print("  \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(value)") }
        let window = since.map { "since \(Self.day($0))" } ?? "all recorded usage"
        Swift.print("dshift savings, \(window)\n")
        guard report.turns > 0 || report.jevCalls > 0 else {
            Swift.print("  Nothing recorded yet. Turns are recorded as they go through the dshift proxy")
            Swift.print("  (`dshift claude`, `dshift codex`, or apps routed with `dshift apps enable`).")
            return
        }

        let money = [report.baselineCost, report.actualCost, report.jevCost, report.savings].map(SavingsReport.dollars)
        let width = money.map(\.count).max() ?? 0
        func amount(_ index: Int) -> String { String(repeating: " ", count: width - money[index].count) + money[index] }
        let baselineNote = baselines.isEmpty ? "" : "  at \(baselines.joined(separator: ", "))"
        line("without dshift", amount(0) + baselineNote)
        line("with dshift", amount(1))
        line("jev routing", amount(2) + "  \(report.jevCalls) call\(report.jevCalls == 1 ? "" : "s")"
             + (report.unpricedJevCalls > 0 ? ", \(report.unpricedJevCalls) unpriced and not counted" : ""))
        let percent = report.baselineCost > 0 ? String(format: "  (%.0f%% of the baseline)", report.savings / report.baselineCost * 100) : ""
        line(report.savings < 0 ? "cost more" : "saved", amount(3) + percent)
        Swift.print("")

        line("turns", "\(report.turns) (\(report.routedTurns) routed, \(report.manualTurns) your own pick)"
             + (report.unpricedTurns > 0 ? ", \(report.unpricedTurns) unpriced and left out" : ""))
        if let rate = report.overrideRate {
            line("overrides", String(format: "%.0f%%", rate * 100)
                 + " of turns in \(report.sessionsRouted) routed session\(report.sessionsRouted == 1 ? "" : "s") used a model you picked")
        }
        let tokens = report.tokens
        line("tokens", "\(SavingsReport.count(tokens.input)) input, \(SavingsReport.count(tokens.cacheRead)) cache read, "
             + "\(SavingsReport.count(tokens.cacheWrite)) cache write, \(SavingsReport.count(tokens.output)) output")
        Swift.print("")

        let nameWidth = max(20, report.models.map(\.model.count).max() ?? 0)
        Swift.print("  \("model".padding(toLength: nameWidth, withPad: " ", startingAt: 0))  turns        cost")
        for model in report.models {
            let turns = String(model.turns)
            let cost = model.cost.map(SavingsReport.dollars) ?? "unpriced"
            Swift.print("  \(model.model.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
                        + String(repeating: " ", count: max(0, 5 - turns.count)) + turns
                        + String(repeating: " ", count: max(1, 12 - cost.count)) + cost)
        }
        Swift.print("")

        if !report.unpricedModels.isEmpty {
            line("unpriced", report.unpricedModels.joined(separator: ", "))
            line("", "add them to \(pricing.file.path)")
        }
        let overrides = pricing.table.overridden.count
        line("prices", "list prices of \(PriceTable.builtInDate)"
             + (overrides > 0 ? ", \(overrides) from \(pricing.file.path)" : ""))
        Swift.print("")
        Swift.print("""
              An estimate at API list prices. On a subscription (Claude Pro/Max, ChatGPT) you
              aren't billed per token, so read it as the API-equivalent cost. The baseline
              assumes the same tokens on the baseline model; switching models also discards
              the prompt cache, and that extra cost is already in "with dshift".
            """)
    }

    static func json(_ report: SavingsReport, since: Date?, baselines: [String],
                     pricing: (table: PriceTable, file: URL, problem: String?)) -> JSONValue {
        func tokens(_ usage: TokenUsage) -> JSONValue {
            ["input": .number(usage.input), "cache_write": .number(usage.cacheWrite),
             "cache_read": .number(usage.cacheRead), "output": .number(usage.output)]
        }
        func usd(_ value: Double) -> JSONValue { .number((value * 1_000_000).rounded() / 1_000_000) }
        return [
            "since": since.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "baselines": .array(baselines.map(JSONValue.string)),
            "baseline_cost": usd(report.baselineCost),
            "actual_cost": usd(report.actualCost),
            "jev_cost": usd(report.jevCost),
            "savings": usd(report.savings),
            "turns": .number(report.turns),
            "routed_turns": .number(report.routedTurns),
            "manual_turns": .number(report.manualTurns),
            "unpriced_turns": .number(report.unpricedTurns),
            "jev_calls": .number(report.jevCalls),
            "unpriced_jev_calls": .number(report.unpricedJevCalls),
            "unpriced_models": .array(report.unpricedModels.map(JSONValue.string)),
            "override_rate": report.overrideRate.map(JSONValue.number) ?? .null,
            "routed_sessions": .number(report.sessionsRouted),
            "tokens": tokens(report.tokens),
            "jev_tokens": tokens(report.jevTokens),
            "models": .array(report.models.map { model in
                ["model": .string(model.model), "turns": .number(model.turns), "tokens": tokens(model.tokens),
                 "cost": model.cost.map(usd) ?? .null]
            }),
            "prices_as_of": .string(PriceTable.builtInDate),
            "prices_file": .string(pricing.file.path),
        ]
    }

    static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
