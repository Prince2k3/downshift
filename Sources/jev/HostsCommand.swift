import ArgumentParser
import Foundation
import JevCore
import JevHosts
import JevProxy

struct HostsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hosts",
        abstract: "See and test the hosts jev can reach Jev through.",
        discussion: """
            jev asks the first host whose credentials are set, in the order `jev hosts list` shows,
            unless JEV_HOST (or `jev serve --host`) names one, or a comma-separated failover list.
            Credentials come from the environment, the keychain (`jev setup`), ./.env,
            ~/.jev-router.env or ~/.jev-claude.env, the first place a variable is set winning.
            """,
        subcommands: [List.self, Test.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show every host, whether it is configured, and which one serve would use.")

        @Option(help: "Resolve as `jev serve --host` would.") var host: String?

        func run() {
            let environment = JevEnvironment.load()
            for preset in HostPresets.all {
                let state: String
                switch HostPresets.host(preset.id, environment: environment) {
                case .success(let host):
                    let fromKeychain = preset.setup.contains { environment.storedKeys.contains($0.variable) }
                    state = "configured  \(host.format.rawValue)  \(Self.endpoint(host.url))  model \(host.model)"
                        + (fromKeychain ? "  (keychain)" : "")
                case .failure(let problem): state = "not configured (\(problem.message))"
                }
                print("\(preset.id.padding(toLength: 11, withPad: " ", startingAt: 0)) \(preset.summary)")
                print("            \(state)")
                print("            reads \(preset.variables.joined(separator: ", "))")
            }
            print()
            let resolution = HostPresets.resolve(flag: host, environment: environment)
            if resolution.hosts.isEmpty {
                print("serve would use: no host (\(resolution.source)); routing stays off")
            } else {
                print("serve would use: \(resolution.hosts.map(\.id).joined(separator: " then ")) (\(resolution.source))")
            }
            for problem in resolution.problems { print("  problem  \(problem)") }
            if !environment.loadedFiles.isEmpty {
                print("env files: \(environment.loadedFiles.map(\.path).joined(separator: ", "))")
            }
            if let problem = environment.credentialProblem { print("keychain: \(problem)") }
            if resolution.hosts.isEmpty { print("\nRun `jev setup` to add one.") }
        }

        /// The URL without anything that could identify the account beyond the host name.
        static func endpoint(_ url: String) -> String {
            guard let components = URLComponents(string: url), let host = components.host else { return "?" }
            return "\(components.scheme ?? "https")://\(host)/…"
        }
    }

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask Jev a fixed probe question through each host and show exactly what happened.",
            discussion: """
                Tests every configured host separately, or those named by --host. The probe prompt is fixed
                and contains nothing of yours. Exits non-zero if any tested host fails.
                """
        )

        @Option(help: "Host id, or a comma-separated list, to test.") var host: String?
        @Option(help: "Prompt to route instead of the built-in probe.") var prompt = Test.probePrompt
        @Option(help: "Seconds to allow each host (serve allows 3).") var timeout: Double = 15
        @Flag(help: "Print the request and the host's raw reply.") var json = false

        func run() async throws {
            let environment = JevEnvironment.load()
            var hosts: [JevHost] = []
            if let host {
                let resolution = HostPresets.resolve(flag: host, environment: environment)
                for problem in resolution.problems { print("\(problem)") }
                hosts = resolution.hosts
            } else {
                hosts = HostPresets.all.compactMap { try? HostPresets.host($0.id, environment: environment).get() }
            }
            guard !hosts.isEmpty else {
                print("no configured host to test; run `jev setup`")
                throw ExitCode(1)
            }

            var failed = false
            for (index, host) in hosts.enumerated() {
                if index > 0 { print() }
                if await !Self.probe(host, environment: environment, prompt: prompt, timeout: timeout, json: json) { failed = true }
            }
            if failed { throw ExitCode(1) }
        }

        static let probePrompt = "Rename the variable `tmp` to `total` in utils.swift."

        /// Asks one host the probe question, prints what happened, and says whether it produced a usable answer.
        static func probe(_ host: JevHost, environment: JevEnvironment, prompt: String = probePrompt,
                          timeout: Double = 15, json: Bool = false) async -> Bool {
            let settings = JevSettings(environment: environment)
            let models = ClaudeAdapter.models(catalog: []).filter { settings.availableTiers.contains($0.tier) }
            let route = RouteRequest(prompt: prompt, current: models.first?.id ?? "", contextTokens: 12_000, models: models)
            let deadline = Duration.milliseconds(Int(timeout * 1000))
            let timing = JevClient.Timing(attemptTimeout: deadline, retries: 0, deadline: deadline)
            let client = JevClient(hosts: [host], timing: timing, keepReplies: true)
            return report(host, await JevRouting.ask(client, route), json: json)
        }

        /// Prints one host's test and says whether it produced a usable answer.
        static func report(_ host: JevHost, _ result: JevRouting.Result, json: Bool) -> Bool {
            print("\(host.id)  (\(host.format.rawValue), model \(host.model))")
            guard let request = result.request, let outcome = result.outcome else {
                print("  FAILED  \(result.problem ?? "no request")")
                return false
            }
            let requestViolations = JevRequestSchema.schema.validate(request.json)
            print("  request schema   \(requestViolations.isEmpty ? "valid" : "\(requestViolations.count) problems")")
            for violation in requestViolations { print("    \(violation)") }
            if json { print("  request\n\(Self.indent(host.httpRequest(request).body))") }

            for attempt in outcome.attempts {
                var line = "  attempt          \(attempt.reason)"
                if let status = attempt.status { line += "  HTTP \(status)" }
                line += "  \(attempt.milliseconds) ms"
                print(line)
                if attempt.reason == "schema-invalid", let reply = attempt.reply, let normalized = try? host.normalize(reply) {
                    print("  response schema  invalid")
                    for violation in JevResponseSchema.schema.validate(normalized) { print("    \(violation)") }
                } else if let message = attempt.message {
                    print("    \(message)")
                }
                if json, let reply = attempt.reply { print("  reply\n\(Self.indent(reply))") }
            }

            guard let reply = outcome.result else {
                print("  FAILED  \(outcome.failure ?? "unknown")")
                return false
            }
            print("  response schema  valid")
            print("  jev model        \(reply.model)  (\(reply.inputTokens) in, \(reply.outputTokens) out)")
            for key in reply.answers.keys.sorted() {
                guard let answer = reply.answers[key] else { continue }
                let confidence = answer.confidence.map { String(format: "  confidence %.2f", $0) } ?? ""
                if let choice = answer.choice {
                    print("  \(key.padding(toLength: 18, withPad: " ", startingAt: 0)) \(choice)\(confidence)")
                } else if let score = answer.score {
                    print("  \(key.padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(format: "%g", score)) / \(RoutingQuestion.complexityMaxScore)\(confidence)")
                }
            }
            if let answer = result.answer {
                print("  OK  routes to \(answer.choice) in \(outcome.milliseconds) ms")
                return true
            }
            print("  FAILED  \(result.problem ?? "no answer")")
            return false
        }

        static func indent(_ value: JSONValue) -> String {
            let text = String(decoding: value.serialized(indent: 2), as: UTF8.self)
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a host's credentials that `jev setup` saved in the keychain.",
            discussion: "Env files and environment variables are yours to edit; this only touches the keychain.")

        @Argument(help: "Host id (see `jev hosts list`).") var host: String

        func run() throws {
            guard let preset = HostPresets.preset(host.lowercased()) else {
                throw ValidationError("unknown host \(host) (known: \(HostPresets.all.map(\.id).joined(separator: ", ")))")
            }
            let store = CredentialStore.keychain
            let stored = try store.read()
            guard HostCredentials.storedHosts(stored).contains(where: { $0.id == preset.id }) else {
                print("nothing saved for \(preset.id) in the keychain")
                return
            }
            try store.write(HostCredentials.removing(preset, from: stored))
            print("removed \(preset.id) from the keychain")
            SetupCommand.restartProxy()
        }
    }
}
