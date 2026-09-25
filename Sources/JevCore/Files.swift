import Foundation

public struct FileError: Error, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum AtomicFile {
    /// Replaces `target` by writing a temporary file in the same directory and renaming it,
    /// so a reader never sees a half-written file. The new file gets `permissions`.
    public static func write(_ data: Data, to target: URL, permissions: Int) throws {
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).jev-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: permissions]) else {
            throw FileError("could not write \(temporary.path)")
        }
        guard rename(temporary.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw FileError("could not replace \(target.path): \(reason)")
        }
    }

    /// Like `write(_:to:permissions:)`, but follows symlinks (so a dotfiles-managed file stays
    /// a symlink) and keeps the existing file's permissions.
    public static func replace(_ data: Data, at url: URL, newFilePermissions: Int = 0o644) throws {
        let target = url.resolvingSymlinksInPath()
        let existing = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        try write(data, to: target, permissions: existing ?? newFilePermissions)
    }

    /// Creates `directory` with `mode` if needed and tightens it if it already exists.
    /// Fails if another user owns it.
    public static func privateDirectory(_ directory: URL, mode: Int = 0o700) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: mode])
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
    }
}

/// A JSON file edited in place: key order is kept, and the file is re-indented the way it was
/// written (`JSON.stringify(value, null, indent)`, with or without a final newline).
public struct JSONDocument: Sendable {
    public var root: JSONObject
    public var indent: Int
    public var trailingNewline: Bool

    public init(root: JSONObject = JSONObject(), indent: Int = 2, trailingNewline: Bool = true) {
        self.root = root
        self.indent = indent
        self.trailingNewline = trailingNewline
    }

    public enum ParseError: Error, Sendable {
        case invalid(JSONParseError)
        case notAnObject
    }

    /// An absent or blank file is an empty object.
    public init(parsing data: Data?) throws(ParseError) {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            self.init()
            return
        }
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch let error as JSONParseError { throw .invalid(error) } catch {
            throw .invalid(JSONParseError(message: "\(error)", offset: 0))
        }
        guard case .object(let object) = value else { throw .notAnObject }
        self.init(root: object, indent: Self.detectIndent(data), trailingNewline: data.last == 0x0A)
    }

    /// Width of the first indented line; 0 (compact) for a one-line file; 2 (Claude Code's
    /// own) when there are several lines but none indented.
    public static func detectIndent(_ data: Data) -> Int {
        let body = data.reversed().drop { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 }
        if !body.contains(0x0A) { return 0 }
        var count = 0
        var atLineStart = false
        for byte in data {
            if byte == 0x0A { atLineStart = true; count = 0; continue }
            if atLineStart {
                if byte == 0x20 { count += 1; continue }
                if count > 0 { return count }
                atLineStart = false
            }
        }
        return 2
    }

    public func rendered() -> Data {
        var bytes = indent == 0 ? JSONValue.object(root).serialized() : JSONValue.object(root).serialized(indent: indent)
        if trailingNewline { bytes.append(0x0A) }
        return Data(bytes)
    }
}
