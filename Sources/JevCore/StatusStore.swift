import Foundation

/// The latest routing decision per session, one JSON file each, so concurrent sessions can
/// never clobber each other. `jev statusline` and `jev explain` read them.
///
/// Files hold prompt text and exact Jev exchanges, so the directory is 0700 and files 0600.
/// It lives in the per-user temp directory, and files untouched for a week are removed.
/// Every operation is best effort: status display must never interfere with a request.
public struct StatusStore: Sendable {
    public static let staleAfter: TimeInterval = 7 * 24 * 60 * 60
    public static let historyLimit = 20

    public let directory: URL

    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("jev")) {
        self.directory = directory
    }

    /// Nil for a session id with nothing usable in it. Only word characters and `-` are kept,
    /// so an id can never name a path outside the directory.
    public func file(for session: String) -> URL? {
        let safe = String(session.unicodeScalars.filter {
            ($0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"))
        })
        return safe.isEmpty ? nil : directory.appendingPathComponent("\(safe).json")
    }

    /// Publishes a status (a decision, or `{"manual": true, "at": …}`) for the status line.
    public func write(_ status: JSONObject, session: String) {
        guard let file = file(for: session) else { return }
        do {
            try AtomicFile.privateDirectory(directory)
            try AtomicFile.write(Data(JSONValue.object(status).serialized()), to: file, permissions: 0o600)
        } catch {
            return
        }
        if Self.firstWrite() { pruneStale() }
    }

    /// Publishes a routing decision and keeps the last `historyLimit` decisions with it, so
    /// recent exact Jev exchanges can be diagnosed.
    public func writeDecision(_ decision: JSONObject, session: String) {
        var history = read(session: session)?["history"]?.arrayValue ?? []
        history.append(.object(decision))
        var status = decision
        status["history"] = .array(Array(history.suffix(Self.historyLimit)))
        write(status, session: session)
    }

    public func read(session: String) -> JSONObject? {
        guard let file = file(for: session), let data = try? Data(contentsOf: file),
              case .object(let object)? = try? JSONValue.parse(data) else { return nil }
        return object
    }

    /// The session whose status changed most recently, for `jev explain` without an id (the
    /// desktop apps can't pass theirs to a skill).
    public func latestSession() -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name -> (String, Date)? in
            let file = directory.appendingPathComponent(name)
            guard let modified = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date else { return nil }
            return (String(name.dropLast(".json".count)), modified)
        }.max { $0.1 < $1.1 }?.0
    }

    /// Deletes status files not modified for `maxAge`; returns how many.
    @discardableResult
    public func pruneStale(maxAge: TimeInterval = staleAfter, now: Date = Date()) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where name.hasSuffix(".json") {
            let file = directory.appendingPathComponent(name)
            // Another session may have removed or replaced it; ignore failures.
            guard let modified = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > maxAge,
                  (try? FileManager.default.removeItem(at: file)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    /// Pruning runs once per process, on the first write.
    private static let pruneLock = NSLock()
    nonisolated(unsafe) private static var pruned = false

    private static func firstWrite() -> Bool {
        pruneLock.withLock {
            defer { pruned = true }
            return !pruned
        }
    }
}
