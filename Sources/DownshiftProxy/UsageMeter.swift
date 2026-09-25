import Foundation
import DownshiftCore
import NIOCore

/// Where one request's usage is recorded, and what to record it against.
public struct UsageContext: Sendable {
    public var ledger: UsageLedger
    /// `claude` or `codex`.
    public var app: String
    public var session: String
    /// The model the user would have been on without dshift; nil when they picked it themselves.
    public var baseline: String?
    public var routed: Bool
    public var now: @Sendable () -> Date

    public init(ledger: UsageLedger, app: String, session: String, baseline: String?, routed: Bool,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.ledger = ledger
        self.app = app
        self.session = session
        self.baseline = baseline
        self.routed = routed
        self.now = now
    }

    /// Appends what a meter read, if it read any usage.
    public func record(_ reading: UsageMeter.Reading?) {
        guard let reading, !reading.tokens.isEmpty else { return }
        ledger.append(UsageRecord(at: now(), kind: .turn, app: app, session: session,
                                  model: reading.model ?? baseline ?? "unknown", baseline: routed ? baseline : nil,
                                  routed: routed, tokens: reading.tokens))
    }
}

/// Reads the token usage out of a response as it streams past, without changing or keeping it.
///
/// Understands the Messages API (`message_start` + `message_delta` events, or one JSON
/// message) and the Responses API (`response.completed`, or one JSON response). Only those
/// events are parsed; every other event (the reply text) is skipped over as bytes.
public struct UsageMeter: Sendable {
    /// Past this much without an event boundary (or a JSON body this large) it stops reading.
    public static let maxEvent = 16 << 20

    public struct Reading: Sendable, Equatable {
        public var model: String?
        public var tokens: TokenUsage
    }

    enum Mode { case unknown, events, json, off }

    static let usageEvents: Set<String> = ["message_start", "message_delta", "response.completed", "response.done", "response.incomplete"]
    /// The Responses API events that end a response (and carry its usage, if any).
    static let endEvents: Set<String> = ["response.completed", "response.done", "response.incomplete", "response.failed", "error"]
    /// Text every end event contains, so the reply's many other messages skip parsing. A
    /// quote inside a JSON string is escaped, so reply text can't fake these.
    static let endMarkers = ["completed\"", "done\"", "incomplete\"", "failed\"", "\"error\""]

    /// One Responses API WebSocket message from the upstream: whether it ends a response, and
    /// the usage it reports.
    public static func readMessage(_ text: String) -> (ends: Bool, reading: Reading?) {
        guard endMarkers.contains(where: text.contains), let json = try? JSONValue.parse(text),
              let type = json["type"]?.stringValue, endEvents.contains(type) else { return (false, nil) }
        var meter = UsageMeter()
        if let response = json["response"] { meter.readResponse(response) }
        return (true, meter.sawUsage ? Reading(model: meter.model, tokens: meter.tokens) : nil)
    }

    var mode = Mode.unknown
    var pending = ByteBuffer()
    /// How far into `pending` has been searched for an event boundary.
    var scanned = 0
    var model: String?
    var tokens = TokenUsage()
    var sawUsage = false

    public init() {}

    public mutating func feed(_ chunk: ByteBuffer) {
        guard mode != .off else { return }
        var chunk = chunk
        pending.writeBuffer(&chunk)
        if mode == .unknown {
            guard let first = pending.readableBytesView.first(where: { !Self.isWhitespace($0) }) else { return }
            mode = first == UInt8(ascii: "{") ? .json : .events
        }
        if mode == .json {
            if pending.readableBytes > Self.maxEvent { stop() }
            return
        }
        while let end = Self.endOfEvent(pending, from: scanned) {
            let event = pending.readSlice(length: end)!
            scanned = 0
            read(event: event)
        }
        scanned = pending.readableBytes
        pending.discardReadBytes()
        if pending.readableBytes > Self.maxEvent { stop() }
    }

    /// What was read, once the response has ended; nil if it carried no usage.
    public mutating func finish() -> Reading? {
        switch mode {
        case .json:
            if let json = try? JSONValue.parse(pending.readableBytesView) {
                if json["type"]?.stringValue == "message" { readMessage(json) } else { readResponse(json) }
            }
        case .events:
            if pending.readableBytes > 0 { read(event: pending) }
        case .unknown, .off:
            break
        }
        pending = ByteBuffer()
        mode = .off
        return sawUsage ? Reading(model: model, tokens: tokens) : nil
    }

    mutating func stop() {
        mode = .off
        pending = ByteBuffer()
    }

    mutating func read(event: ByteBuffer) {
        var name: String?
        var data: [UInt8] = []
        event.withUnsafeReadableBytes { bytes in
            for var line in bytes.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if line.last == 0x0D { line = line.dropLast() }
                if line.starts(with: "event:".utf8) {
                    name = String(decoding: line.dropFirst(6), as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    // Everything else (the reply text) is left unread.
                    if !Self.usageEvents.contains(name!) { return }
                } else if line.starts(with: "data:".utf8), name.map(Self.usageEvents.contains) == true {
                    var value = line.dropFirst(5)
                    if value.first == 0x20 { value = value.dropFirst() }
                    if !data.isEmpty { data.append(0x0A) }
                    data.append(contentsOf: value)
                }
            }
        }
        guard let name, Self.usageEvents.contains(name), let json = try? JSONValue.parse(data) else { return }
        switch name {
        case "message_start":
            if let message = json["message"] { readMessage(message) }
        case "message_delta":
            if let usage = json["usage"] { readMessagesUsage(usage) }
        default:
            if let response = json["response"] { readResponse(response) }
        }
    }

    /// A Messages API message (or `message_start`'s): the model and its usage so far.
    mutating func readMessage(_ message: JSONValue) {
        if let id = message["model"]?.stringValue { model = id }
        if let usage = message["usage"] { readMessagesUsage(usage) }
    }

    /// Messages API usage. Counts are cumulative, and `message_delta` may carry only some.
    mutating func readMessagesUsage(_ usage: JSONValue) {
        func count(_ key: String) -> Int? { usage[key]?.intValue }
        if let value = count("input_tokens") { tokens.input = value }
        if let value = count("cache_creation_input_tokens") { tokens.cacheWrite = value }
        if let value = count("cache_read_input_tokens") { tokens.cacheRead = value }
        if let value = count("output_tokens") { tokens.output = value }
        sawUsage = true
    }

    /// A Responses API response. Its `input_tokens` includes the cached ones.
    mutating func readResponse(_ response: JSONValue) {
        guard let usage = response["usage"], usage.objectValue != nil else { return }
        if let id = response["model"]?.stringValue { model = id }
        let details = usage["input_tokens_details"]
        let cached = details?["cached_tokens"]?.intValue ?? 0
        let written = details?["cache_write_tokens"]?.intValue ?? 0
        let input = usage["input_tokens"]?.intValue ?? 0
        tokens = TokenUsage(input: max(0, input - cached - written), cacheWrite: written, cacheRead: cached,
                            output: usage["output_tokens"]?.intValue ?? 0)
        sawUsage = true
    }

    /// The length up to and including the first blank line (`\n\n` or `\r\n\r\n`), looking
    /// only at bytes from `from` on (less the few a boundary could straddle).
    static func endOfEvent(_ buffer: ByteBuffer, from: Int = 0) -> Int? {
        buffer.withUnsafeReadableBytes { bytes -> Int? in
            guard bytes.count >= 2 else { return nil }
            for index in max(1, from - 3)..<bytes.count where bytes[index] == 0x0A {
                if bytes[index - 1] == 0x0A { return index + 1 }
                if index >= 3, bytes[index - 1] == 0x0D, bytes[index - 2] == 0x0A { return index + 1 }
            }
            return nil
        }
    }

    static func isWhitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }
}
