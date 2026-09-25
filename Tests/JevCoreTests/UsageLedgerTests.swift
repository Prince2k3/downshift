import Foundation
import Testing
@testable import JevCore

@Suite struct UsageLedgerTests {
    func ledger() throws -> UsageLedger {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jev-ledger-\(UUID().uuidString)")
        return UsageLedger(directory: url.appendingPathComponent("usage"))
    }

    func record(_ at: Date, model: String = "claude-sonnet-5", kind: UsageRecord.Kind = .turn) -> UsageRecord {
        UsageRecord(at: at, kind: kind, app: "claude", session: "s1", model: model, baseline: "claude-opus-5",
                    routed: true, tokens: TokenUsage(input: 10, cacheWrite: 20, cacheRead: 30, output: 40))
    }

    @Test func recordsRoundTripAsFlatPrivateLines() throws {
        let ledger = try ledger()
        let at = Date(timeIntervalSince1970: 1_790_000_000.123)
        ledger.append(record(at))
        ledger.append(record(at.addingTimeInterval(1), model: "jev-small", kind: .jev))
        #expect(ledger.records() == [record(at), record(at.addingTimeInterval(1), model: "jev-small", kind: .jev)])

        let file = ledger.file(for: at)
        let line = try #require(String(contentsOf: file, encoding: .utf8).split(separator: "\n").first)
        #expect(line.hasPrefix(#"{"app":"claude","at":1790000000123,"baseline":"claude-opus-5","cache_read":30"#))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: ledger.directory.path)
        #expect((directory[.posixPermissions] as? Int) == 0o700)
    }

    @Test func filesAreMonthlyInUTCAndSinceFilters() throws {
        let ledger = try ledger()
        let august = ISO8601DateFormatter().date(from: "2026-08-31T23:30:00Z")!
        let september = ISO8601DateFormatter().date(from: "2026-09-01T00:30:00Z")!
        ledger.append(record(august))
        ledger.append(record(september))
        #expect(UsageLedger.month(august) == "2026-08")
        #expect(try FileManager.default.contentsOfDirectory(atPath: ledger.directory.path).sorted()
                == ["usage-2026-08.jsonl", "usage-2026-09.jsonl"])
        #expect(ledger.records(since: september).map(\.at) == [september])
        #expect(ledger.records(since: august.addingTimeInterval(60)).map(\.at) == [september])
        #expect(ledger.records().count == 2)
    }

    @Test func unparseableLinesAreSkipped() throws {
        let ledger = try ledger()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        ledger.append(record(at))
        let handle = try FileHandle(forWritingTo: ledger.file(for: at))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"at\":1}\n".utf8))
        try handle.close()
        ledger.append(record(at.addingTimeInterval(1)))
        #expect(ledger.records().count == 2)
    }

    @Test func oldMonthsArePruned() throws {
        let ledger = try ledger()
        let formatter = ISO8601DateFormatter()
        let old = formatter.date(from: "2025-01-15T00:00:00Z")!
        let kept = formatter.date(from: "2025-09-15T00:00:00Z")!
        ledger.append(record(old))
        ledger.append(record(kept))
        // Starting a new month's file prunes anything older than 13 months.
        ledger.append(record(formatter.date(from: "2026-09-15T00:00:00Z")!))
        #expect(try FileManager.default.contentsOfDirectory(atPath: ledger.directory.path).sorted()
                == ["usage-2025-09.jsonl", "usage-2026-09.jsonl"])
    }

    @Test func standardHonoursHome() {
        let ledger = UsageLedger.standard(environment: ["HOME": "/tmp/jev-home"])
        #if os(macOS)
        #expect(ledger.directory.path == "/tmp/jev-home/Library/Application Support/jev/usage")
        #else
        #expect(ledger.directory.path == "/tmp/jev-home/.local/state/jev/usage")
        #endif
    }
}
