import Foundation

/// Tokens one reply was billed for. `input` excludes cached tokens, so the four counts add up
/// to the prompt plus the reply, each priced at its own rate.
public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }

    public var isEmpty: Bool { input == 0 && cacheWrite == 0 && cacheRead == 0 && output == 0 }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                   cacheRead: lhs.cacheRead + rhs.cacheRead, output: lhs.output + rhs.output)
    }
}

/// One line of the usage ledger: token counts and model ids only, never prompt or reply text.
public struct UsageRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A reply from Claude or Codex that went through the proxy.
        case turn
        /// Jev's own routing call.
        case jev
    }

    public var at: Date
    public var kind: Kind
    /// `claude` or `codex`.
    public var app: String
    public var session: String
    /// The model that answered.
    public var model: String
    /// The model the user would have been on without jev; nil when the user picked the model
    /// themselves (the baseline is then `model`).
    public var baseline: String?
    /// Whether jev chose the model (the request asked for the router).
    public var routed: Bool
    public var tokens: TokenUsage

    public init(at: Date, kind: Kind, app: String, session: String, model: String, baseline: String?,
                routed: Bool, tokens: TokenUsage) {
        self.at = at
        self.kind = kind
        self.app = app
        self.session = session
        self.model = model
        self.baseline = baseline
        self.routed = routed
        self.tokens = tokens
    }

    enum CodingKeys: String, CodingKey {
        case at, kind, app, session, model, baseline, routed
        case input, cacheWrite = "cache_write", cacheRead = "cache_read", output
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .at) / 1000)
        kind = try container.decode(Kind.self, forKey: .kind)
        app = try container.decode(String.self, forKey: .app)
        session = try container.decodeIfPresent(String.self, forKey: .session) ?? ""
        model = try container.decode(String.self, forKey: .model)
        baseline = try container.decodeIfPresent(String.self, forKey: .baseline)
        routed = try container.decodeIfPresent(Bool.self, forKey: .routed) ?? false
        tokens = TokenUsage(input: try container.decodeIfPresent(Int.self, forKey: .input) ?? 0,
                            cacheWrite: try container.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0,
                            cacheRead: try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0,
                            output: try container.decodeIfPresent(Int.self, forKey: .output) ?? 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Int64((at.timeIntervalSince1970 * 1000).rounded()), forKey: .at)
        try container.encode(kind, forKey: .kind)
        try container.encode(app, forKey: .app)
        try container.encode(session, forKey: .session)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(baseline, forKey: .baseline)
        try container.encode(routed, forKey: .routed)
        try container.encode(tokens.input, forKey: .input)
        try container.encode(tokens.cacheWrite, forKey: .cacheWrite)
        try container.encode(tokens.cacheRead, forKey: .cacheRead)
        try container.encode(tokens.output, forKey: .output)
    }
}

/// An append-only record of the tokens every proxied reply used, one JSON line per reply, in
/// one file per month (`usage-2026-09.jsonl`, UTC). `jev savings` prices it.
///
/// Several processes append at once (`jev serve` and any `jev claude`), so each record is one
/// `write` to a file opened with `O_APPEND`. The directory is 0700 and files 0600. Months
/// older than `retentionMonths` are removed when a new month's file is started. Every
/// operation is best effort: the ledger must never interfere with a request.
public struct UsageLedger: Sendable {
    public static let retentionMonths = 13

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/jev/usage` on macOS, `$XDG_STATE_HOME/jev/usage` elsewhere.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> UsageLedger {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        #if os(macOS)
        let root = home.appendingPathComponent("Library/Application Support/jev", isDirectory: true)
        #else
        let state = environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/state", isDirectory: true)
        let root = state.appendingPathComponent("jev", isDirectory: true)
        #endif
        return UsageLedger(directory: root.appendingPathComponent("usage", isDirectory: true))
    }

    /// `2026-09` for a date, in UTC.
    static func month(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    func file(for date: Date) -> URL {
        directory.appendingPathComponent("usage-\(Self.month(date)).jsonl")
    }

    public func append(_ record: UsageRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        guard (try? AtomicFile.privateDirectory(directory)) != nil else { return }
        let file = file(for: record.at)
        let starting = !FileManager.default.fileExists(atPath: file.path)
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        if starting { prune(now: record.at) }
    }

    /// Records at or after `since`, oldest first. Lines that don't parse are skipped.
    public func records(since: Date? = nil) -> [UsageRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let first = since.map { "usage-\(Self.month($0)).jsonl" }
        let decoder = JSONDecoder()
        var records: [UsageRecord] = []
        for name in names.filter(Self.isLedgerFile).sorted() where first.map({ name >= $0 }) ?? true {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let record = try? decoder.decode(UsageRecord.self, from: line) else { continue }
                if let since, record.at < since { continue }
                records.append(record)
            }
        }
        return records.sorted { $0.at < $1.at }
    }

    /// Removes month files older than `retentionMonths`; returns how many.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let cutoff = Calendar(identifier: .gregorian).date(byAdding: .month, value: -Self.retentionMonths, to: now)
        else { return 0 }
        let oldest = "usage-\(Self.month(cutoff)).jsonl"
        var removed = 0
        for name in names.filter(Self.isLedgerFile) where name < oldest {
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    static func isLedgerFile(_ name: String) -> Bool { name.hasPrefix("usage-") && name.hasSuffix(".jsonl") }
}
