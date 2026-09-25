import Foundation
import DownshiftCore

/// One reason an instance does not satisfy a schema.
public struct SchemaViolation: Sendable, Hashable, CustomStringConvertible {
    /// JSON Pointer into the instance (`""` is the root).
    public var instancePath: String
    public var keyword: String
    public var message: String

    public var description: String {
        "\(instancePath.isEmpty ? "/" : instancePath): \(message) [\(keyword)]"
    }
}

public struct SchemaError: Error, Sendable, CustomStringConvertible {
    public var schemaPath: String
    public var message: String
    public var description: String { "invalid schema at \(schemaPath.isEmpty ? "/" : schemaPath): \(message)" }
}

/// A JSON Schema (draft 2020-12) validator for the subset of the spec that the Jev request
/// schema uses, plus a few common siblings. Unknown keywords are rejected when the schema is
/// loaded, so a future schema revision can never be half-validated without anyone noticing.
public struct JSONSchema: Sendable {
    public static let supportedKeywords: Set<String> = [
        // identifiers and annotations
        "$schema", "$id", "$defs", "$ref", "$comment", "title", "description", "default", "examples",
        // assertions
        "type", "const", "enum", "required", "minLength", "maxLength", "minItems", "maxItems",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        // applicators
        "properties", "additionalProperties", "propertyNames", "items", "anyOf", "oneOf", "allOf", "not",
    ]

    public let root: JSONValue

    public init(_ root: JSONValue) throws {
        self.root = root
        try Self.check(root, path: "")
    }

    public init(json: String) throws {
        try self.init(JSONValue.parse(json))
    }

    public func validate(_ instance: JSONValue) -> [SchemaViolation] {
        var violations: [SchemaViolation] = []
        _ = evaluate(root, instance, path: "", refDepth: 0, into: &violations)
        return violations
    }

    public func isValid(_ instance: JSONValue) -> Bool {
        var sink: [SchemaViolation] = []
        return evaluate(root, instance, path: "", refDepth: 0, into: &sink)
    }

    // MARK: Schema checking

    private static func check(_ schema: JSONValue, path: String) throws {
        switch schema {
        case .bool:
            return
        case .object(let object):
            for entry in object.entries {
                let keyPath = path + "/" + escape(entry.key)
                guard supportedKeywords.contains(entry.key) else {
                    throw SchemaError(schemaPath: keyPath, message: "unsupported keyword \"\(entry.key)\"")
                }
                switch entry.key {
                case "$defs", "properties":
                    guard case .object(let children) = entry.value else {
                        throw SchemaError(schemaPath: keyPath, message: "must be an object")
                    }
                    for child in children.entries { try check(child.value, path: keyPath + "/" + escape(child.key)) }
                case "additionalProperties", "propertyNames", "items", "not":
                    try check(entry.value, path: keyPath)
                case "anyOf", "oneOf", "allOf":
                    guard case .array(let branches) = entry.value, !branches.isEmpty else {
                        throw SchemaError(schemaPath: keyPath, message: "must be a non-empty array")
                    }
                    for (i, branch) in branches.enumerated() { try check(branch, path: keyPath + "/\(i)") }
                case "$ref":
                    guard case .string(let ref) = entry.value, ref.hasPrefix("#") else {
                        throw SchemaError(schemaPath: keyPath, message: "only local references (#…) are supported")
                    }
                case "type":
                    let names: [JSONValue]
                    switch entry.value {
                    case .string: names = [entry.value]
                    case .array(let list): names = list
                    default: throw SchemaError(schemaPath: keyPath, message: "must be a string or array")
                    }
                    for name in names {
                        guard let n = name.stringValue, typeNames.contains(n) else {
                            throw SchemaError(schemaPath: keyPath, message: "unknown type \(name.serializedString())")
                        }
                    }
                case "required":
                    guard case .array(let list) = entry.value, list.allSatisfy({ $0.stringValue != nil }) else {
                        throw SchemaError(schemaPath: keyPath, message: "must be an array of strings")
                    }
                case "minLength", "maxLength", "minItems", "maxItems":
                    guard let n = entry.value.intValue, n >= 0 else {
                        throw SchemaError(schemaPath: keyPath, message: "must be a non-negative integer")
                    }
                case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum":
                    guard case .number(let literal) = entry.value, Decimal(string: literal) != nil else {
                        throw SchemaError(schemaPath: keyPath, message: "must be a number")
                    }
                case "enum":
                    guard case .array = entry.value else {
                        throw SchemaError(schemaPath: keyPath, message: "must be an array")
                    }
                default:
                    break
                }
            }
        default:
            throw SchemaError(schemaPath: path, message: "a schema must be an object or a boolean")
        }
    }

    private static let typeNames: Set<String> = ["null", "boolean", "object", "array", "number", "integer", "string"]

    // MARK: Evaluation

    private func evaluate(
        _ schema: JSONValue, _ instance: JSONValue, path: String, refDepth: Int,
        into violations: inout [SchemaViolation]
    ) -> Bool {
        switch schema {
        case .bool(true): return true
        case .bool(false):
            violations.append(.init(instancePath: path, keyword: "false", message: "no value is allowed here"))
            return false
        case .object(let keywords):
            var valid = true
            func fail(_ keyword: String, _ message: String) {
                violations.append(.init(instancePath: path, keyword: keyword, message: message))
                valid = false
            }

            if case .string(let ref)? = keywords["$ref"] {
                if refDepth > 64 {
                    fail("$ref", "reference cycle")
                } else if let target = resolve(ref) {
                    if !evaluate(target, instance, path: path, refDepth: refDepth + 1, into: &violations) { valid = false }
                } else {
                    fail("$ref", "unresolvable reference \(ref)")
                }
            }

            if let type = keywords["type"] {
                let allowed = type.arrayValue?.compactMap(\.stringValue) ?? [type.stringValue ?? ""]
                if !allowed.contains(where: { Self.matches(type: $0, instance) }) {
                    fail("type", "expected \(allowed.joined(separator: " or ")), got \(Self.typeName(instance))")
                }
            }

            if let constant = keywords["const"], !Self.equal(constant, instance) {
                fail("const", "must equal \(constant.serializedString())")
            }

            if case .array(let options)? = keywords["enum"], !options.contains(where: { Self.equal($0, instance) }) {
                fail("enum", "must be one of \(JSONValue.array(options).serializedString())")
            }

            if case .string(let s) = instance {
                let length = s.unicodeScalars.count
                if let min = keywords["minLength"]?.intValue, length < min {
                    fail("minLength", "must be at least \(min) character\(min == 1 ? "" : "s") long")
                }
                if let max = keywords["maxLength"]?.intValue, length > max {
                    fail("maxLength", "must be at most \(max) characters long")
                }
            }

            if case .number(let literal) = instance {
                for (keyword, message) in Self.boundViolations(literal, keywords) { fail(keyword, message) }
            }

            if case .array(let items) = instance {
                if let min = keywords["minItems"]?.intValue, items.count < min {
                    fail("minItems", "must have at least \(min) items, has \(items.count)")
                }
                if let max = keywords["maxItems"]?.intValue, items.count > max {
                    fail("maxItems", "must have at most \(max) items, has \(items.count)")
                }
                if let itemSchema = keywords["items"] {
                    for (i, item) in items.enumerated()
                    where !evaluate(itemSchema, item, path: path + "/\(i)", refDepth: 0, into: &violations) {
                        valid = false
                    }
                }
            }

            if case .object(let object) = instance {
                if case .array(let required)? = keywords["required"] {
                    for name in required.compactMap(\.stringValue) where !object.contains(key: name) {
                        fail("required", "missing required property \"\(name)\"")
                    }
                }
                let properties = keywords["properties"]?.objectValue
                for entry in object.entries {
                    let childPath = path + "/" + Self.escape(entry.key)
                    if let propertySchema = properties?[entry.key] {
                        if !evaluate(propertySchema, entry.value, path: childPath, refDepth: 0, into: &violations) {
                            valid = false
                        }
                    } else if let additional = keywords["additionalProperties"] {
                        if case .bool(false) = additional {
                            fail("additionalProperties", "unexpected property \"\(entry.key)\"")
                        } else if !evaluate(additional, entry.value, path: childPath, refDepth: 0, into: &violations) {
                            valid = false
                        }
                    }
                    if let nameSchema = keywords["propertyNames"] {
                        var nameViolations: [SchemaViolation] = []
                        if !evaluate(nameSchema, .string(entry.key), path: childPath, refDepth: 0, into: &nameViolations) {
                            for v in nameViolations {
                                violations.append(.init(instancePath: v.instancePath, keyword: "propertyNames",
                                                        message: "property name \"\(entry.key)\": \(v.message)"))
                            }
                            valid = false
                        }
                    }
                }
            }

            if case .array(let branches)? = keywords["allOf"] {
                for branch in branches where !evaluate(branch, instance, path: path, refDepth: refDepth, into: &violations) {
                    valid = false
                }
            }

            if case .array(let branches)? = keywords["anyOf"] {
                let results = branches.map { branch -> [SchemaViolation] in
                    var sink: [SchemaViolation] = []
                    _ = evaluate(branch, instance, path: path, refDepth: refDepth, into: &sink)
                    return sink
                }
                if !results.contains(where: \.isEmpty) {
                    fail("anyOf", "does not match any allowed shape")
                    violations.append(contentsOf: Self.closest(results))
                }
            }

            if case .array(let branches)? = keywords["oneOf"] {
                let results = branches.map { branch -> [SchemaViolation] in
                    var sink: [SchemaViolation] = []
                    _ = evaluate(branch, instance, path: path, refDepth: refDepth, into: &sink)
                    return sink
                }
                let matches = results.filter(\.isEmpty).count
                if matches == 0 {
                    fail("oneOf", "does not match any allowed shape")
                    violations.append(contentsOf: Self.closest(results))
                } else if matches > 1 {
                    fail("oneOf", "matches \(matches) shapes but must match exactly one")
                }
            }

            if let negated = keywords["not"] {
                var sink: [SchemaViolation] = []
                if evaluate(negated, instance, path: path, refDepth: refDepth, into: &sink) {
                    fail("not", "must not match the negated schema")
                }
            }

            return valid
        default:
            return true  // rejected by check(_:path:)
        }
    }

    /// Numeric bounds, kept out of `evaluate` so its frame stays small for deep `$ref` chains.
    /// Decimal compares the literals exactly, so bounds like 2^53 - 1 are not rounded.
    private static func boundViolations(_ literal: String, _ keywords: JSONObject) -> [(String, String)] {
        guard let value = Decimal(string: literal) else { return [] }
        var found: [(String, String)] = []
        for (keyword, violated, message) in [
            ("minimum", { (v: Decimal, b: Decimal) in v < b }, "must be at least"),
            ("maximum", { $0 > $1 }, "must be at most"),
            ("exclusiveMinimum", { $0 <= $1 }, "must be greater than"),
            ("exclusiveMaximum", { $0 >= $1 }, "must be less than"),
        ] as [(String, (Decimal, Decimal) -> Bool, String)] {
            guard case .number(let text)? = keywords[keyword], let bound = Decimal(string: text),
                  violated(value, bound) else { continue }
            found.append((keyword, "\(message) \(text)"))
        }
        return found
    }

    /// The failing branch with the fewest violations is the most useful to report
    /// (for example the `choice` branch when `type` is `"choice"`).
    private static func closest(_ results: [[SchemaViolation]]) -> [SchemaViolation] {
        results.min(by: { $0.count < $1.count }) ?? []
    }

    private func resolve(_ ref: String) -> JSONValue? {
        guard ref.hasPrefix("#") else { return nil }
        let pointer = ref.dropFirst()
        if pointer.isEmpty { return root }
        guard pointer.hasPrefix("/") else { return nil }
        var node = root
        for rawToken in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = rawToken.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch node {
            case .object(let object):
                guard let next = object[token] else { return nil }
                node = next
            case .array(let array):
                guard let i = Int(token), array.indices.contains(i) else { return nil }
                node = array[i]
            default:
                return nil
            }
        }
        return node
    }

    // MARK: Helpers

    static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    static func matches(type: String, _ value: JSONValue) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("number", .number), ("string", .string),
             ("array", .array), ("object", .object):
            return true
        case ("integer", .number(let literal)):
            guard let d = Double(literal) else { return false }
            return d.isFinite && d.rounded() == d
        default:
            return false
        }
    }

    /// JSON Schema equality: numbers compare by value, objects ignore key order.
    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y || Double(x) == Double(y)
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object(let x), .object(let y)):
            let xk = Set(x.keys), yk = Set(y.keys)
            guard xk == yk else { return false }
            return xk.allSatisfy { key in equal(x[key]!, y[key]!) }
        default: return false
        }
    }
}
