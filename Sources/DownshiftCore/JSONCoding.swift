public struct JSONParseError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var offset: Int
    public var description: String { "JSON parse error at byte \(offset): \(message)" }
}

extension JSONValue {
    /// Maximum nesting depth accepted by the parser. Parsing, serializing, equality and schema
    /// validation all recurse, and Swift concurrency threads have small stacks, so this matches
    /// serde_json's limit rather than something larger (512 overflowed a debug-build task).
    public static let maxDepth = 128

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Array(text.utf8))
    }

    public static func parse<Bytes: Collection<UInt8>>(_ bytes: Bytes) throws -> JSONValue {
        let array = Array(bytes)
        return try array.withUnsafeBufferPointer { buffer in
            var parser = JSONParser(buffer)
            parser.skipWhitespace()
            let value = try parser.parseValue(depth: 0)
            parser.skipWhitespace()
            guard parser.index == buffer.count else { throw parser.error("unexpected trailing data") }
            return value
        }
    }

    /// Compact serialization. Strings are escaped exactly like `JSON.stringify` (and
    /// serde_json): `"` `\\` `\b` `\f` `\n` `\r` `\t` get short escapes, other control
    /// characters become lowercase `\u00xx`, everything else is emitted as raw UTF-8.
    public func serialized() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        JSONSerializer.write(self, into: &out)
        return out
    }

    public func serializedString() -> String {
        String(decoding: serialized(), as: UTF8.self)
    }

    /// Pretty serialization identical to `JSON.stringify(value, null, indent)`, which is how
    /// Claude Code writes `settings.json`: one member per line, `": "` after keys, and empty
    /// objects and arrays kept as `{}` / `[]`. No trailing newline.
    public func serialized(indent: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        JSONSerializer.writePretty(self, indent: indent, level: 0, into: &out)
        return out
    }
}

// MARK: - Parser

private struct JSONParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < JSONValue.maxDepth else { throw error("nesting too deep") }
        guard index < bytes.count else { throw error("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("unexpected character")
        }
    }

    mutating func expect(_ literal: StaticString) throws {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw error("unexpected end of input") }
        for i in 0..<count where bytes[index + i] != literal.utf8Start[i] {
            throw error("invalid literal")
        }
        index += count
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1  // {
        var entries: [JSONObject.Entry] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(JSONObject(entries))
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
            index += 1
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            entries.append(JSONObject.Entry(key: key, value: value))
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end of input") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(JSONObject(entries)) }
            throw error("expected ',' or '}'")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1  // [
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end of input") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw error("expected ',' or ']'")
        }
    }

    mutating func parseNumber() throws -> String {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw error("invalid number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if isDigit(bytes[index]) {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        } else {
            throw error("invalid number")
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid number fraction") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid number exponent") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
    }

    func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    mutating func parseString() throws -> String {
        index += 1  // opening quote
        let start = index
        // Fast path: no escapes.
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                index += 1
                return s
            }
            if byte == UInt8(ascii: "\\") { break }
            if byte < 0x20 { throw error("unescaped control character in string") }
            index += 1
        }
        var scratch = Array(UnsafeBufferPointer(rebasing: bytes[start..<index]))
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: scratch, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw error("unterminated escape") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scratch.append(0x22)
                case UInt8(ascii: "\\"): scratch.append(0x5C)
                case UInt8(ascii: "/"): scratch.append(0x2F)
                case UInt8(ascii: "b"): scratch.append(0x08)
                case UInt8(ascii: "f"): scratch.append(0x0C)
                case UInt8(ascii: "n"): scratch.append(0x0A)
                case UInt8(ascii: "r"): scratch.append(0x0D)
                case UInt8(ascii: "t"): scratch.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    scratch.append(contentsOf: String(Character(scalar)).utf8)
                default:
                    throw error("invalid escape")
                }
            default:
                if byte < 0x20 { throw error("unescaped control character in string") }
                scratch.append(byte)
                index += 1
            }
        }
        throw error("unterminated string")
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("truncated \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("invalid hex digit")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    /// Decodes `XXXX` after `\u`, combining surrogate pairs. A lone surrogate cannot be
    /// represented in a Swift `String`, so it becomes U+FFFD.
    mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try parseHex4()
        if (0xD800...0xDBFF).contains(first) {
            if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let save = index
                index += 2
                let second = try parseHex4()
                if (0xDC00...0xDFFF).contains(second) {
                    let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Unicode.Scalar(combined) ?? "\u{FFFD}"
                }
                index = save
            }
            return "\u{FFFD}"
        }
        return Unicode.Scalar(first) ?? "\u{FFFD}"
    }
}

// MARK: - Serializer

private enum JSONSerializer {
    static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    static func write(_ value: JSONValue, into out: inout [UInt8]) {
        switch value {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
        case .number(let n): out.append(contentsOf: n.utf8)
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                write(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            out.append(UInt8(ascii: "{"))
            for (i, entry) in object.entries.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                writeString(entry.key, into: &out)
                out.append(UInt8(ascii: ":"))
                write(entry.value, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    static func writePretty(_ value: JSONValue, indent: Int, level: Int, into out: inout [UInt8]) {
        func newline(_ level: Int) {
            out.append(UInt8(ascii: "\n"))
            out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: indent * level))
        }
        switch value {
        case .array(let items) where !items.isEmpty:
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                newline(level + 1)
                writePretty(item, indent: indent, level: level + 1, into: &out)
            }
            newline(level)
            out.append(UInt8(ascii: "]"))
        case .object(let object) where !object.entries.isEmpty:
            out.append(UInt8(ascii: "{"))
            for (i, entry) in object.entries.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                newline(level + 1)
                writeString(entry.key, into: &out)
                out.append(contentsOf: [UInt8(ascii: ":"), UInt8(ascii: " ")])
                writePretty(entry.value, indent: indent, level: level + 1, into: &out)
            }
            newline(level)
            out.append(UInt8(ascii: "}"))
        default:
            write(value, into: &out)
        }
    }

    static func writeString(_ string: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x00..<0x20:
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"),
                                        hex[Int(byte >> 4)], hex[Int(byte & 0xF)]])
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
