import ArgumentParser
import Foundation
import JevCore
import JevHosts

struct SchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Work with Jev's JSON Schemas (request and response).",
        subcommands: [Check.self, Show.self]
    )

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate a systemOne request or response body against Jev's schema.",
            discussion: """
                Pass a file, or - for stdin. A top-level "model" field in a request is reported separately, \
                because the TypeSafe API accepts it but Cloudflare's schema does not; use --strip-model to \
                validate the body as the Cloudflare host would send it. With --response, the body is \
                checked as Jev's reply (after any host envelope has been removed).
                """
        )

        @Argument(help: "Body file, or - for stdin.")
        var file: String

        @Flag(help: "Check a response instead of a request.")
        var response = false

        @Flag(help: "Remove a top-level \"model\" field from a request before validating.")
        var stripModel = false

        func run() throws {
            let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile()
                                   : try Data(contentsOf: URL(fileURLWithPath: file))
            var body = try JSONValue.parse(data)
            if stripModel && !response { body["model"] = nil }
            let kind = response ? "response" : "request"
            let violations = (response ? JevResponseSchema.schema : JevRequestSchema.schema).validate(body)
            if violations.isEmpty {
                print("\(kind) schema: valid")
                return
            }
            print("\(kind) schema: \(violations.count) problem\(violations.count == 1 ? "" : "s")")
            for violation in violations { print("  \(violation)") }
            throw ExitCode(1)
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a bundled schema.")
        @Flag(help: "Print the response schema instead of the request schema.") var response = false
        func run() { print(response ? JevResponseSchema.json : JevRequestSchema.json) }
    }
}
