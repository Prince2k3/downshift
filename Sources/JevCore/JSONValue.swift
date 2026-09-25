/// Order-preserving JSON value.
///
/// Request bodies sent by Claude Code and Codex are undocumented and must round-trip
/// unknown fields unchanged. `JSONSerialization` and `[String: Any]` lose key order, and
/// reordered `tools[].input_schema` or `system` blocks can change the rendered prompt and
/// silently break prompt-cache hits. So objects keep their entries in source order
/// (duplicates included) and numbers keep their original literal text.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// The number exactly as written in the source (validated against the JSON grammar).
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// An ordered list of key/value entries. Lookups return the last entry for a key,
/// matching `JSON.parse` semantics; writes replace in place so order is kept.
public struct JSONObject: Sendable, Hashable, RandomAccessCollection, ExpressibleByDictionaryLiteral {
    public struct Entry: Sendable, Hashable {
        public var key: String
        public var value: JSONValue
        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public var entries: [Entry]

    public init(_ entries: [Entry] = []) { self.entries = entries }
    public init(_ pairs: [(String, JSONValue)]) { self.entries = pairs.map { Entry(key: $0.0, value: $0.1) } }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self.init(elements) }

    public var startIndex: Int { entries.startIndex }
    public var endIndex: Int { entries.endIndex }
    public subscript(position: Int) -> Entry { entries[position] }

    public var keys: [String] { entries.map(\.key) }

    public subscript(key: String) -> JSONValue? {
        get { entries.last(where: { $0.key == key })?.value }
        set {
            guard let newValue else {
                entries.removeAll { $0.key == key }
                return
            }
            if let index = entries.lastIndex(where: { $0.key == key }) {
                entries[index].value = newValue
            } else {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }

    public func contains(key: String) -> Bool { entries.contains { $0.key == key } }
}

// MARK: - Convenience accessors

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let object) = self else { return nil }
            return object[key]
        }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return Double(n) }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let n) = self else { return nil }
        if let i = Int(n) { return i }
        if let d = Double(n), d.rounded() == d, let i = Int(exactly: d) { return i }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public static func number(_ value: Int) -> JSONValue { .number(String(value)) }

    public static func number(_ value: Double) -> JSONValue {
        if value.rounded() == value, abs(value) < 1e15 { return .number(String(Int(value))) }
        return .number(String(value))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByIntegerLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
    public init(integerLiteral value: Int) { self = .number(String(value)) }
}
