import Foundation

/// What one model costs, in US dollars per million tokens.
public struct ModelPrice: Codable, Equatable, Sendable {
    public var input: Double
    /// Writing the prompt cache (Anthropic's 5-minute rate; OpenAI doesn't charge extra, so its input rate).
    public var cacheWrite: Double
    public var cacheRead: Double
    public var output: Double

    public init(input: Double, cacheWrite: Double? = nil, cacheRead: Double? = nil, output: Double) {
        self.input = input
        self.cacheWrite = cacheWrite ?? input
        self.cacheRead = cacheRead ?? input
        self.output = output
    }

    enum CodingKeys: String, CodingKey {
        case input, cacheWrite = "cache_write", cacheRead = "cache_read", output
    }

    /// A missing cache rate is charged at the input rate.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let input = try container.decode(Double.self, forKey: .input)
        self.init(input: input,
                  cacheWrite: try container.decodeIfPresent(Double.self, forKey: .cacheWrite),
                  cacheRead: try container.decodeIfPresent(Double.self, forKey: .cacheRead),
                  output: try container.decode(Double.self, forKey: .output))
    }

    /// The dollars these tokens cost at this price.
    public func cost(_ tokens: TokenUsage) -> Double {
        (Double(tokens.input) * input + Double(tokens.cacheWrite) * cacheWrite
            + Double(tokens.cacheRead) * cacheRead + Double(tokens.output) * output) / 1_000_000
    }
}

/// List prices for the models jev routes between, plus any the user adds or corrects in
/// `prices.json`. A model it doesn't know is unpriced (nil), never free.
public struct PriceTable: Sendable {
    /// When the built-in prices were taken from the providers' pricing pages.
    public static let builtInDate = "2026-09-25"

    /// Standard-tier API list prices, keyed by normalized model id.
    public static let builtIn: [String: ModelPrice] = {
        var prices: [String: ModelPrice] = [:]
        func anthropic(_ ids: [String], _ input: Double, _ cacheRead: Double, _ output: Double) {
            for id in ids { prices[id] = ModelPrice(input: input, cacheWrite: input * 1.25, cacheRead: cacheRead, output: output) }
        }
        anthropic(["claude-fable-5-1", "claude-mythos-5-1"], 10, 0.25, 50)
        anthropic(["claude-fable-5", "claude-mythos-5"], 10, 1, 50)
        anthropic(["claude-opus-5-5"], 4, 0.20, 20)
        anthropic(["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"], 5, 0.50, 25)
        anthropic(["claude-opus-4-1", "claude-opus-4"], 15, 1.50, 75)
        anthropic(["claude-sonnet-5"], 2, 0.20, 10)
        anthropic(["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4"], 3, 0.30, 15)
        anthropic(["claude-haiku-4-5"], 1, 0.10, 5)
        anthropic(["claude-3-5-haiku", "claude-haiku-3-5"], 0.80, 0.08, 4)

        func openAI(_ ids: [String], _ input: Double, _ cached: Double, _ output: Double) {
            for id in ids { prices[id] = ModelPrice(input: input, cacheWrite: input, cacheRead: cached, output: output) }
        }
        openAI(["gpt-6-astra"], 10, 1, 50)
        openAI(["gpt-6-sol"], 2, 0.20, 10)
        openAI(["gpt-6-luna"], 0.10, 0.01, 0.50)
        openAI(["gpt-5.6-sol"], 4, 0.40, 20)
        openAI(["gpt-5.6-terra"], 2, 0.20, 12)
        openAI(["gpt-5.6-luna"], 0.20, 0.02, 1.20)
        openAI(["gpt-5.5"], 5, 0.50, 30)
        openAI(["gpt-5.4"], 2.50, 0.25, 15)
        openAI(["gpt-5.4-mini"], 0.75, 0.075, 4.50)
        openAI(["gpt-5.4-nano"], 0.20, 0.02, 1.25)
        openAI(["gpt-5.2"], 1.75, 0.175, 14)
        openAI(["gpt-5.1", "gpt-5"], 1.25, 0.125, 10)

        // Jev itself, on every host: `typesafe/jev`, `jev-latest`, `typesafe-ai/jev` and
        // `~typesafe/jev-latest` all normalize to `jev`. Only uncached input is charged.
        prices["jev"] = ModelPrice(input: 0.042, cacheWrite: 0, cacheRead: 0, output: 0)
        return prices
    }()

    public var prices: [String: ModelPrice]
    /// The models `prices.json` added or changed.
    public var overridden: Set<String>

    public init(prices: [String: ModelPrice] = PriceTable.builtIn, overrides: [String: ModelPrice] = [:]) {
        var merged = prices
        for (id, price) in overrides { merged[Self.normalize(id)] = price }
        self.prices = merged
        self.overridden = Set(overrides.keys.map(Self.normalize))
    }

    public func price(for model: String) -> ModelPrice? { prices[Self.normalize(model)] }

    /// What these tokens cost on `model`; nil if the model is unpriced.
    public func cost(_ tokens: TokenUsage, model: String) -> Double? { price(for: model)?.cost(tokens) }

    /// `Anthropic/Claude-Opus-4-8[1m]` and `claude-opus-4-8-20260101` → `claude-opus-4-8`;
    /// `openai/gpt-5-2025-08-07` → `gpt-5`.
    public static func normalize(_ model: String) -> String {
        var id = model.trimmingCharacters(in: .whitespaces).lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        if id.hasSuffix("-latest") { id.removeLast("-latest".count) }
        for pattern in [#"-\d{4}-\d{2}-\d{2}$"#, #"-\d{8}$"#] {
            if let range = id.range(of: pattern, options: .regularExpression) { id.removeSubrange(range) }
        }
        return id
    }

    // MARK: Overrides

    /// `$XDG_CONFIG_HOME/jev/prices.json`, else `~/.config/jev/prices.json`.
    public static func overrideFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true)
        return config.appendingPathComponent("jev/prices.json")
    }

    struct OverrideFile: Decodable {
        var models: [String: ModelPrice]
    }

    /// The built-in prices plus `prices.json`, if it exists:
    /// `{"models": {"jev-latest": {"input": 0.1, "output": 0.4, "cache_read": 0.01}}}`.
    /// A file that doesn't parse is reported and ignored.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> (table: PriceTable, file: URL, problem: String?) {
        let file = overrideFile(environment: environment)
        guard let data = FileManager.default.contents(atPath: file.path) else { return (PriceTable(), file, nil) }
        do {
            let overrides = try JSONDecoder().decode(OverrideFile.self, from: data)
            return (PriceTable(overrides: overrides.models), file, nil)
        } catch {
            return (PriceTable(), file, "\(file.path) is not valid (\(Self.describe(error))); using the built-in prices")
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, let context)?:
            return "missing \"\(key.stringValue)\"" + (context.codingPath.last.map { " in \"\($0.stringValue)\"" } ?? "")
        case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?:
            return "wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted?:
            return "not JSON"
        default:
            return "unreadable"
        }
    }
}
