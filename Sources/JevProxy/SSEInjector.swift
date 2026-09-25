import NIOCore

/// Inserts extra Server-Sent Events after the first event of a stream. Codex draws the
/// decision only once the response has started (`response.created`), so the frames go
/// right after it.
///
/// Works on bytes, never on decoded text: a chunk boundary can fall inside a multi-byte
/// UTF-8 character, and decoding chunks one at a time would corrupt it (plan bug #3). The
/// stream's own bytes are forwarded exactly.
public struct SSEInjector: Sendable {
    /// Past this much without a blank line the stream isn't SSE; give up and pass through.
    public static let maxFirstEvent = 1 << 20

    let frames: ByteBuffer
    var pending = ByteBuffer()
    var done = false
    /// Whether the frames were inserted (false until then, and if the stream wasn't SSE).
    public private(set) var injected = false

    public init(frames: ByteBuffer) { self.frames = frames }

    /// The bytes to forward for one upstream chunk (possibly none yet).
    public mutating func feed(_ chunk: ByteBuffer) -> [ByteBuffer] {
        if done { return [chunk] }
        var chunk = chunk
        pending.writeBuffer(&chunk)
        guard let end = Self.endOfFirstEvent(pending) else {
            if pending.readableBytes > Self.maxFirstEvent { return [flush()] }
            return []
        }
        done = true
        let first = pending.readSlice(length: end)!
        let rest = pending
        pending = ByteBuffer()
        guard Self.isSSE(first) else { return [first, rest].filter { $0.readableBytes > 0 } }
        injected = true
        return [first, frames, rest].filter { $0.readableBytes > 0 }
    }

    /// Whatever is still held when the upstream ends.
    public mutating func finish() -> ByteBuffer? {
        guard !done, pending.readableBytes > 0 else { return nil }
        return flush()
    }

    mutating func flush() -> ByteBuffer {
        done = true
        defer { pending = ByteBuffer() }
        return pending
    }

    /// The length up to and including the first `\n\n`.
    static func endOfFirstEvent(_ buffer: ByteBuffer) -> Int? {
        buffer.withUnsafeReadableBytes { bytes -> Int? in
            guard bytes.count >= 2 else { return nil }
            for index in 1..<bytes.count where bytes[index] == 0x0A && bytes[index - 1] == 0x0A {
                return index + 1
            }
            return nil
        }
    }

    /// Whether any line starts with `event:` or `data:`.
    static func isSSE(_ event: ByteBuffer) -> Bool {
        event.withUnsafeReadableBytes { bytes in
            bytes.split(separator: 0x0A, omittingEmptySubsequences: true).contains { line in
                line.starts(with: "event:".utf8) || line.starts(with: "data:".utf8)
            }
        }
    }
}
