import DownshiftCore

/// Content allowed for `state`, `instructions` and criteria values by the Jev request schema:
/// a string, an object of any JSON, an array of any JSON, or null. Bare numbers and booleans
/// are not allowed there, so this type cannot express them.
public enum JevPayload: Sendable, Hashable {
    case text(String)
    case object(JSONObject)
    case array([JSONValue])
    case null

    public var json: JSONValue {
        switch self {
        case .text(let s): .string(s)
        case .object(let o): .object(o)
        case .array(let a): .array(a)
        case .null: .null
        }
    }
}

extension JevPayload: ExpressibleByStringLiteral, ExpressibleByNilLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByArrayLiteral
{
    public init(stringLiteral value: String) { self = .text(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

public struct QuestionError: Error, Sendable, CustomStringConvertible {
    public var description: String
}

/// One Jev question, shaped exactly like the schema's three `oneOf` branches.
public enum JevQuestion: Sendable, Hashable {
    /// Yes/no. `criteria` is either omitted, `null`, or describes the `true`/`false` outcomes.
    case noul(instructions: JevPayload, criteria: NoulCriteria?)
    /// Pick one label. Criteria keep their order because it is part of the prompt Jev sees.
    case choice(instructions: JevPayload, criteria: [(label: String, description: JevPayload)])
    /// Score on an ordered rubric indexed from zero; at least two entries.
    case score(instructions: JevPayload, criteria: [JevPayload])

    public enum NoulCriteria: Sendable, Hashable {
        case null
        case outcomes(whenTrue: JevPayload?, whenFalse: JevPayload?)
    }

    public static func noul(_ instructions: JevPayload = nil, criteria: NoulCriteria? = nil) -> JevQuestion {
        .noul(instructions: instructions, criteria: criteria)
    }

    public static func choice(_ instructions: JevPayload, _ criteria: [(String, JevPayload)]) -> JevQuestion {
        .choice(instructions: instructions, criteria: criteria.map { (label: $0.0, description: $0.1) })
    }

    public static func score(_ instructions: JevPayload, _ criteria: [JevPayload]) throws -> JevQuestion {
        guard criteria.count >= 2 else {
            throw QuestionError(description: "a score question needs at least 2 criteria, got \(criteria.count)")
        }
        return .score(instructions: instructions, criteria: criteria)
    }

    public var json: JSONValue {
        switch self {
        case .noul(let instructions, let criteria):
            var object: JSONObject = ["type": "noul", "instructions": instructions.json]
            switch criteria {
            case nil: break
            case .null?: object["criteria"] = .null
            case .outcomes(let whenTrue, let whenFalse)?:
                var outcomes = JSONObject()
                if let whenTrue { outcomes["true"] = whenTrue.json }
                if let whenFalse { outcomes["false"] = whenFalse.json }
                object["criteria"] = .object(outcomes)
            }
            return .object(object)
        case .choice(let instructions, let criteria):
            return .object([
                "type": "choice",
                "instructions": instructions.json,
                "criteria": .object(JSONObject(criteria.map { ($0.label, $0.description.json) })),
            ])
        case .score(let instructions, let criteria):
            return .object([
                "type": "score",
                "instructions": instructions.json,
                "criteria": .array(criteria.map(\.json)),
            ])
        }
    }

    public static func == (lhs: JevQuestion, rhs: JevQuestion) -> Bool { lhs.json == rhs.json }
    public func hash(into hasher: inout Hasher) { hasher.combine(json) }
}

/// A systemOne request exactly as the Jev request schema defines it: `{state, questions}`.
/// There is deliberately no `model` field; hosts that need one add it on the wire.
public struct SystemOneRequest: Sendable, Hashable {
    public var state: JevPayload
    /// Keys in send order. Keys must be non-empty.
    public private(set) var questions: [(key: String, question: JevQuestion)]

    public init(state: JevPayload, questions: [(String, JevQuestion)]) throws {
        self.state = state
        self.questions = []
        for (key, question) in questions { try add(key, question) }
    }

    public mutating func add(_ key: String, _ question: JevQuestion) throws {
        guard !key.isEmpty else { throw QuestionError(description: "question keys must not be empty") }
        if let i = questions.firstIndex(where: { $0.key == key }) {
            questions[i].question = question
        } else {
            questions.append((key, question))
        }
    }

    /// The schema-exact body.
    public var json: JSONValue {
        .object([
            "state": state.json,
            "questions": .object(JSONObject(questions.map { ($0.key, $0.question.json) })),
        ])
    }

    /// The wire body for a host. `model` is appended last, matching the TypeSafe SDK's order,
    /// only for hosts whose API expects it (the schema itself forbids it).
    public func wireBody(model: String?) -> JSONValue {
        var body = json
        if let model { body["model"] = .string(model) }
        return body
    }

    public static func == (lhs: SystemOneRequest, rhs: SystemOneRequest) -> Bool { lhs.json == rhs.json }
    public func hash(into hasher: inout Hasher) { hasher.combine(json) }
}

/// One answer, shaped exactly like the Jev response schema's three `oneOf` branches.
public enum JevAnswer: Sendable, Hashable {
    /// The probability, from 0 to 1, that the statement is true.
    case noul(Double)
    case choice(choice: String, probabilities: [String: Double], confidence: Double)
    /// `legend` maps each score to the rubric entry it stands for.
    case score(score: Double, legend: [String: String], probabilities: [String: Double], confidence: Double)

    public var choice: String? {
        if case .choice(let choice, _, _) = self { return choice }
        return nil
    }

    public var score: Double? {
        if case .score(let score, _, _, _) = self { return score }
        return nil
    }

    public var confidence: Double? {
        switch self {
        case .noul: nil
        case .choice(_, _, let confidence), .score(_, _, _, let confidence): confidence
        }
    }

    /// Decodes an answer that has already passed the schema.
    init?(_ json: JSONValue) {
        func numbers(_ value: JSONValue?) -> [String: Double] {
            Dictionary((value?.objectValue?.entries ?? []).compactMap { entry in entry.value.doubleValue.map { (entry.key, $0) } },
                       uniquingKeysWith: { $1 })
        }
        switch json["type"]?.stringValue {
        case "noul":
            guard let p = json["noul"]?.doubleValue else { return nil }
            self = .noul(p)
        case "choice":
            guard let choice = json["choice"]?.stringValue, let confidence = json["confidence"]?.doubleValue else { return nil }
            self = .choice(choice: choice, probabilities: numbers(json["probabilities"]), confidence: confidence)
        case "score":
            guard let score = json["score"]?.doubleValue, let confidence = json["confidence"]?.doubleValue else { return nil }
            let legend = Dictionary((json["legend"]?.objectValue?.entries ?? []).compactMap { entry in
                entry.value.stringValue.map { (entry.key, $0) }
            }, uniquingKeysWith: { $1 })
            self = .score(score: score, legend: legend, probabilities: numbers(json["probabilities"]), confidence: confidence)
        default:
            return nil
        }
    }
}

public struct JevResponseError: Error, Sendable, CustomStringConvertible {
    public var violations: [SchemaViolation]
    public var description: String {
        "response does not match Jev's schema: " + violations.prefix(3).map(\.description).joined(separator: "; ")
            + (violations.count > 3 ? " (+\(violations.count - 3) more)" : "")
    }
}

/// A systemOne response, exactly as Jev's response schema defines it: `{model, answers, usage}`.
/// It can only be built from JSON that passes the schema.
public struct SystemOneResult: Sendable, Hashable {
    public var model: String
    public var answers: [String: JevAnswer]
    public var inputTokens: Int
    public var outputTokens: Int
    /// The validated JSON.
    public var json: JSONValue

    public init(json: JSONValue) throws {
        let violations = JevResponseSchema.schema.validate(json)
        guard violations.isEmpty else { throw JevResponseError(violations: violations) }
        self.json = json
        model = json["model"]?.stringValue ?? ""
        var answers: [String: JevAnswer] = [:]
        for entry in json["answers"]?.objectValue?.entries ?? [] {
            answers[entry.key] = JevAnswer(entry.value)
        }
        self.answers = answers
        // The schema allows up to 2^53-1, which fits in Int on every 64-bit platform.
        inputTokens = json["usage"]?["input_tokens"]?.intValue ?? 0
        outputTokens = json["usage"]?["output_tokens"]?.intValue ?? 0
    }
}
