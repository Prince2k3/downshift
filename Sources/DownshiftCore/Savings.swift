import Foundation

/// What routing saved over a stretch of the usage ledger: each turn's tokens priced at the
/// model that answered and at the baseline (the model the conversation would have stayed on),
/// less what Jev's own routing calls cost.
public struct SavingsReport: Sendable, Equatable {
    public struct ModelLine: Sendable, Equatable {
        public var model: String
        public var turns: Int
        public var tokens: TokenUsage
        /// Nil when the model is unpriced.
        public var cost: Double?
    }

    public var turns = 0
    public var routedTurns = 0
    public var manualTurns = 0
    /// Turns left out of both costs because the model or its baseline is unpriced.
    public var unpricedTurns = 0
    public var unpricedModels: [String] = []
    /// Priced turns only.
    public var actualCost = 0.0
    public var baselineCost = 0.0
    public var jevCalls = 0
    public var jevCost = 0.0
    public var unpricedJevCalls = 0
    public var tokens = TokenUsage()
    public var jevTokens = TokenUsage()
    public var models: [ModelLine] = []
    /// Manual turns in sessions dshift routed, over all turns in those sessions: how often the
    /// user overrode the pick.
    public var sessionsRouted = 0
    public var overrideTurns = 0
    public var turnsInRoutedSessions = 0

    public var savings: Double { baselineCost - actualCost - jevCost }
    public var overrideRate: Double? { turnsInRoutedSessions == 0 ? nil : Double(overrideTurns) / Double(turnsInRoutedSessions) }

    /// - Parameters:
    ///   - baseline: prices every routed turn against this model instead of its recorded
    ///     baseline. Manual turns stay their own baseline: the user would have picked the same.
    ///   - app: only records from `claude` or `codex`.
    public init(records: [UsageRecord], prices: PriceTable, baseline: String? = nil, app: String? = nil) {
        var byModel: [String: ModelLine] = [:]
        var unpriced = Set<String>()
        var sessions: [String: (routed: Bool, turns: Int, manual: Int)] = [:]

        for record in records where app.map({ record.app == $0 }) ?? true {
            switch record.kind {
            case .jev:
                jevCalls += 1
                jevTokens = jevTokens + record.tokens
                if let cost = prices.cost(record.tokens, model: record.model) {
                    jevCost += cost
                } else {
                    unpricedJevCalls += 1
                    unpriced.insert(record.model)
                }
            case .turn:
                turns += 1
                tokens = tokens + record.tokens
                if record.routed { routedTurns += 1 } else { manualTurns += 1 }
                if !record.session.isEmpty {
                    var session = sessions[record.session] ?? (false, 0, 0)
                    session.turns += 1
                    if record.routed { session.routed = true } else { session.manual += 1 }
                    sessions[record.session] = session
                }

                let actual = prices.cost(record.tokens, model: record.model)
                let baselineModel = record.routed ? (baseline ?? record.baseline ?? record.model) : record.model
                let base = prices.cost(record.tokens, model: baselineModel)
                var line = byModel[record.model] ?? ModelLine(model: record.model, turns: 0, tokens: TokenUsage(), cost: 0)
                line.turns += 1
                line.tokens = line.tokens + record.tokens
                line.cost = actual.flatMap { cost in line.cost.map { $0 + cost } }
                byModel[record.model] = line
                if let actual, let base {
                    actualCost += actual
                    baselineCost += base
                } else {
                    unpricedTurns += 1
                    if actual == nil { unpriced.insert(record.model) }
                    if base == nil { unpriced.insert(baselineModel) }
                }
            }
        }

        models = byModel.values.sorted { ($0.cost ?? -1, $0.turns, $1.model) > ($1.cost ?? -1, $1.turns, $0.model) }
        unpricedModels = unpriced.sorted()
        for session in sessions.values where session.routed {
            sessionsRouted += 1
            overrideTurns += session.manual
            turnsInRoutedSessions += session.turns
        }
    }
}

/// `dshift savings --since`: `7d`, `24h`, `2w`, `all`, or a date (`2026-09-01`, UTC).
public enum SincePeriod {
    public static func parse(_ text: String, now: Date = Date()) -> Date?? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "all" { return .some(nil) }
        if let unit = text.last, let count = Int(text.dropLast()), count > 0 {
            let hours: Int? = switch unit {
            case "h": count
            case "d": count * 24
            case "w": count * 24 * 7
            default: nil
            }
            if let hours { return .some(now.addingTimeInterval(-Double(hours) * 3600)) }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        if let date = formatter.date(from: text) { return .some(date) }
        return nil
    }
}

extension SavingsReport {
    /// `$12.34`, or `$0.0042` under a cent, so small amounts don't read as zero.
    public static func dollars(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let amount = abs(value)
        return sign + (amount >= 0.01 || amount == 0 ? String(format: "$%.2f", amount) : String(format: "$%.4f", amount))
    }

    /// `1.2M`, `340k`, `512`.
    public static func count(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: "\(value / 1000)k"
        case 1000...: String(format: "%.1fk", Double(value) / 1000)
        default: "\(value)"
        }
    }

    /// One line for `dshift status`.
    public var summary: String {
        guard turns > 0 else { return "no turns recorded" }
        var text = "\(Self.dollars(savings)) saved over \(turns) turn\(turns == 1 ? "" : "s")"
        if baselineCost > 0 { text += String(format: " (%.0f%%)", savings / baselineCost * 100) }
        if unpricedTurns > 0 || unpricedJevCalls > 0 { text += ", some unpriced" }
        return text
    }
}
