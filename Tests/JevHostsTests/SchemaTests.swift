import Foundation
import Testing
@testable import DownshiftCore
@testable import JevHosts

@Suite struct JevRequestSchemaTests {
    let schema = JevRequestSchema.schema

    func violations(_ json: String) throws -> [SchemaViolation] {
        schema.validate(try JSONValue.parse(json))
    }

    @Test func embeddedCopyMatchesCheckedInFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schemas/jev-systemone-request.schema.json")
        let onDisk = try JSONValue.parse(Data(contentsOf: file))
        #expect(onDisk == (try JSONValue.parse(JevRequestSchema.json)),
                "run scripts/embed-schema.sh after editing the schema")
    }

    @Test func routingRequestConforms() throws {
        let request = try RoutingQuestion.request(
            prompt: "Fix the flaky test in auth.spec.ts", currentModel: "claude-sonnet-5", contextTokens: 1234,
            models: [
                .init(id: "claude-haiku-4-5-20251001", tier: .fast),
                .init(id: "claude-sonnet-5", tier: .balanced, description: "Sonnet 5"),
                .init(id: "claude-opus-5", tier: .strong),
            ])
        let found = schema.validate(request.json)
        #expect(found.isEmpty, "\(found)")
        #expect(request.json.objectValue?.keys == ["state", "questions"])
        #expect(request.json["questions"]?.objectValue?.keys ==
                ["task_complexity", "reasoning_required", "tool_complexity", "model"])
    }

    @Test func typesafeModelFieldIsRejectedByTheSchema() throws {
        let request = try RoutingQuestion.request(prompt: "hi", currentModel: "m", contextTokens: 0,
                                                  models: [.init(id: "m", tier: .balanced)])
        let wire = request.wireBody(model: "jev-latest")
        #expect(wire.objectValue?.keys.last == "model")
        #expect(schema.validate(wire).map(\.keyword) == ["additionalProperties"])
    }

    @Test func allQuestionShapesConform() throws {
        let request = try SystemOneRequest(state: "I was charged twice.", questions: [
            ("billing", .noul("Is this about billing?")),
            ("billing_null", .noul("Is this about billing?", criteria: .null)),
            ("refund", .noul(["ask": "refund?"], criteria: .outcomes(whenTrue: "wants money back", whenFalse: nil))),
            ("topic", .choice(nil, [("billing", "Money"), ("tech", ["a", 1])])),
            ("urgency", try .score("How urgent?", ["low", nil, ["x": 1]])),
        ])
        #expect(schema.validate(request.json).isEmpty)
    }

    @Test func scoreNeedsTwoCriteria() {
        #expect(throws: QuestionError.self) { try JevQuestion.score("q", ["only one"]) }
    }

    @Test func emptyQuestionKeysAreRejectedByTheType() {
        #expect(throws: QuestionError.self) { try SystemOneRequest(state: nil, questions: [("", .noul())]) }
    }

    @Test("invalid requests are caught", arguments: [
        (#"{"questions":{}}"#, "required"),
        (#"{"state":null}"#, "required"),
        (#"{"state":5,"questions":{}}"#, "anyOf"),
        (#"{"state":true,"questions":{}}"#, "anyOf"),
        (#"{"state":null,"questions":{"":{"type":"noul","instructions":null}}}"#, "propertyNames"),
        (#"{"state":null,"questions":{"q":{"type":"noul"}}}"#, "oneOf"),
        (#"{"state":null,"questions":{"q":{"type":"score","instructions":"x","criteria":["one"]}}}"#, "oneOf"),
        (#"{"state":null,"questions":{"q":{"type":"choice","instructions":"x"}}}"#, "oneOf"),
        (#"{"state":null,"questions":{"q":{"type":"choice","instructions":"x","criteria":["a","b"]}}}"#, "oneOf"),
        (#"{"state":null,"questions":{"q":{"type":"noul","instructions":null,"extra":1}}}"#, "oneOf"),
        (#"{"state":null,"questions":{"q":{"type":"noul","instructions":null,"criteria":{"maybe":"x"}}}}"#, "oneOf"),
        (#"{"state":null,"questions":{"q":{"type":"guess","instructions":null}}}"#, "oneOf"),
        (#"{"state":null,"questions":{"q":{"type":"noul","instructions":7}}}"#, "oneOf"),
        (#"{"state":null,"questions":[]}"#, "type"),
    ] as [(String, String)])
    func rejects(_ json: String, keyword: String) throws {
        let found = try violations(json)
        #expect(found.contains { $0.keyword == keyword }, "expected \(keyword), got \(found)")
    }

    @Test func oneOfReportsTheClosestBranch() throws {
        let found = try violations(#"{"state":null,"questions":{"q":{"type":"score","instructions":"x","criteria":["one"]}}}"#)
        #expect(found.contains { $0.keyword == "minItems" && $0.instancePath == "/questions/q/criteria" })
    }

    @Test func noulCriteriaMayBeOmittedOrNull() throws {
        #expect(try violations(#"{"state":"s","questions":{"a":{"type":"noul","instructions":null}}}"#).isEmpty)
        #expect(try violations(#"{"state":"s","questions":{"a":{"type":"noul","instructions":null,"criteria":null}}}"#).isEmpty)
        #expect(try violations(#"{"state":"s","questions":{"a":{"type":"noul","instructions":null,"criteria":{"true":"y","false":null}}}}"#).isEmpty)
    }
}

@Suite struct SchemaValidatorTests {
    @Test func unknownKeywordsFailLoudly() {
        #expect(throws: SchemaError.self) { try JSONSchema(json: #"{"type":"string","pattern":"^a"}"#) }
        #expect(throws: SchemaError.self) { try JSONSchema(json: #"{"anyOf":[{"format":"email"}]}"#) }
    }

    @Test func remoteRefsAreRejected() {
        #expect(throws: SchemaError.self) { try JSONSchema(json: #"{"$ref":"https://example.com/s.json"}"#) }
    }

    @Test func oneOfRequiresExactlyOne() throws {
        let schema = try JSONSchema(json: #"{"oneOf":[{"type":"string"},{"minLength":1}]}"#)
        #expect(schema.isValid("") )
        #expect(!schema.isValid("abc"))
        #expect(schema.validate("abc").first?.keyword == "oneOf")
    }

    @Test func constComparesNumbersByValue() throws {
        let schema = try JSONSchema(json: #"{"const":1.0}"#)
        #expect(schema.isValid(.number("1")))
        #expect(!schema.isValid(.number("2")))
    }

    @Test func minLengthCountsCodePoints() throws {
        let schema = try JSONSchema(json: #"{"minLength":2}"#)
        #expect(!schema.isValid("🌍"))
        #expect(schema.isValid("🌍🌍"))
    }

    @Test func selfReferenceCycleIsReported() throws {
        let schema = try JSONSchema(json: ##"{"$defs":{"a":{"$ref":"#/$defs/a"}},"$ref":"#/$defs/a"}"##)
        #expect(schema.validate(nil).contains { $0.message == "reference cycle" })
    }

    @Test func pointerEscapesInPaths() throws {
        let schema = try JSONSchema(json: #"{"additionalProperties":{"type":"string"}}"#)
        #expect(schema.validate(["a/b~c": 1]).first?.instancePath == "/a~1b~0c")
    }
}

struct RoutingQuestionTests {
    @Test func scoreRubricsKeepTenCriteriaOrFewer() {
        #expect(RoutingQuestion.complexityScale.count <= 10)
        for (key, question) in RoutingQuestion.scores {
            guard case .score(_, let criteria) = question else {
                Issue.record("\(key) is not a score question")
                continue
            }
            #expect((2...10).contains(criteria.count), "\(key)")
        }
    }
}

@Suite struct JevResponseSchemaTests {
    let schema = JevResponseSchema.schema

    func violations(_ json: String) throws -> [SchemaViolation] {
        schema.validate(try JSONValue.parse(json))
    }

    @Test func embeddedCopyMatchesCheckedInFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schemas/jev-systemone-response.schema.json")
        let onDisk = try JSONValue.parse(Data(contentsOf: file))
        #expect(onDisk == (try JSONValue.parse(JevResponseSchema.json)),
                "run scripts/embed-schema.sh after editing the schema")
    }

    static let valid = """
        {"model":"systemone-1",
         "answers":{
           "model":{"type":"choice","choice":"claude-sonnet-5","probabilities":{"claude-sonnet-5":0.8,"claude-opus-5":0.2},"confidence":0.8},
           "reasoningRequired":{"type":"noul","noul":0.91},
           "difficulty":{"type":"score","score":3,"legend":{"1":"trivial","5":"hard"},"probabilities":{"3":0.6,"4":0.4},"confidence":0.6}},
         "usage":{"input_tokens":1234,"output_tokens":9007199254740991}}
        """

    @Test func everyAnswerShapeConforms() throws {
        #expect(try violations(Self.valid).isEmpty)
    }

    @Test("invalid responses are caught", arguments: [
        (#"{"model":"m","answers":{},"usage":{"input_tokens":1,"output_tokens":1},"extra":1}"#, "additionalProperties"),
        (#"{"model":"","answers":{},"usage":{"input_tokens":1,"output_tokens":1}}"#, "minLength"),
        (#"{"model":"m","answers":{}}"#, "required"),
        (#"{"model":"m","answers":{"q":{"type":"noul","noul":1.5}},"usage":{"input_tokens":1,"output_tokens":1}}"#, "maximum"),
        (#"{"model":"m","answers":{"q":{"type":"noul","noul":-0.1}},"usage":{"input_tokens":1,"output_tokens":1}}"#, "minimum"),
        (#"{"model":"m","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":2},"confidence":0.5}},"usage":{"input_tokens":1,"output_tokens":1}}"#, "maximum"),
        (#"{"model":"m","answers":{"q":{"type":"choice","choice":"a","probabilities":{}}},"usage":{"input_tokens":1,"output_tokens":1}}"#, "required"),
        (#"{"model":"m","answers":{"":{"type":"noul","noul":0}},"usage":{"input_tokens":1,"output_tokens":1}}"#, "propertyNames"),
        (#"{"model":"m","answers":{},"usage":{"input_tokens":1.5,"output_tokens":1}}"#, "type"),
        (#"{"model":"m","answers":{},"usage":{"input_tokens":-1,"output_tokens":1}}"#, "minimum"),
        (#"{"model":"m","answers":{},"usage":{"input_tokens":1,"output_tokens":9007199254740992}}"#, "maximum"),
    ])
    func invalid(json: String, keyword: String) throws {
        let found = try violations(json)
        #expect(found.contains { $0.keyword == keyword }, "\(found)")
    }
}

@Suite struct NumericBoundTests {
    @Test func exclusiveBoundsAndBadBoundValues() throws {
        let schema = try JSONSchema(json: #"{"exclusiveMinimum":0,"exclusiveMaximum":1}"#)
        #expect(schema.validate(.number("0.5")).isEmpty)
        #expect(!schema.validate(.number("0")).isEmpty)
        #expect(!schema.validate(.number("1")).isEmpty)
        #expect(schema.validate(.string("not a number")).isEmpty)
        #expect(throws: SchemaError.self) { try JSONSchema(json: #"{"minimum":"0"}"#) }
    }
}
