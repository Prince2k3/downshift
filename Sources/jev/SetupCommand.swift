import ArgumentParser
import Foundation
import JevAgents
import JevCore
import JevHosts

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up the Jev host that picks each prompt's model; saved in your keychain.",
        discussion: """
            Asks which host to use (Cloudflare unless you pick another) and for its credentials,
            tests them with a fixed probe prompt, and saves them in the login keychain, never
            in a file. Run it again to change a value or add a failover host;
            `jev hosts remove <host>` deletes one.
            Without a terminal:
              printf %s "$TOKEN" | jev setup --host cloudflare --set CLOUDFLARE_ACCOUNT_ID=<id> --key-stdin
            After jev is upgraded, macOS asks once whether jev may read the item: choose Always Allow.
            """
    )

    @Option(help: "Host to set up (see `jev hosts list`); asks when omitted.") var host: String?
    @Option(name: .customLong("set"), help: ArgumentHelp("A non-secret value, as VARIABLE=value (repeatable).", valueName: "VARIABLE=value"))
    var values: [String] = []
    @Flag(help: "Read the API key or token from stdin instead of asking.") var keyStdin = false
    @Flag(help: "Save without testing the host first.") var noTest = false
    @Flag(name: .customLong("default"), help: "Make this host the one jev asks first.") var makeDefault = false

    func run() async throws {
        let interactive = Prompt.isInteractive && !keyStdin
        let store = CredentialStore.keychain
        let stored = try store.read()
        let process = ProcessInfo.processInfo.environment
        let fileEnvironment = JevEnvironment.load(credentials: nil)

        guard let preset = try choosePreset(interactive: interactive, stored: stored, environment: fileEnvironment) else {
            throw ValidationError("pass --host (one of \(HostPresets.all.map(\.id).joined(separator: ", "))) when not in a terminal")
        }
        var answers = try answersFromFlags(preset)
        if interactive { print("\nSetting up \(preset.id): \(preset.summary)") }
        for field in preset.setup where answers[field.variable] == nil {
            answers[field.variable] = try ask(field, saved: stored[field.variable], interactive: interactive)
        }
        var updated = HostCredentials.applying(answers, to: stored)

        // What jev will see: the shell environment, then the keychain, then env files.
        var environment = fileEnvironment
        for (key, value) in updated where process[key] == nil { environment.values[key] = value }
        let host: JevHost
        switch HostPresets.host(preset.id, environment: environment) {
        case .success(let built): host = built
        case .failure(let problem): throw AppsError("\(problem); nothing saved")
        }
        for field in preset.setup where process[field.variable] != nil && process[field.variable] != updated[field.variable] {
            print("note: \(field.variable) is also set in your shell environment, which wins over the keychain in this shell")
        }

        if !noTest {
            print("\nTesting \(preset.id)…")
            if await !HostsCommand.Test.probe(host, environment: environment) {
                guard interactive, Prompt.confirm("\nSave anyway?", default: false) else {
                    throw AppsError("\(preset.id) didn't answer; nothing saved (--no-test saves without testing)")
                }
            }
        }

        let first = HostPresets.resolve(environment: environment).hosts.first?.id
        if first != preset.id {
            let current = first.map { "jev asks \($0) first now" } ?? "jev doesn't use \(preset.id) yet"
            if makeDefault || (interactive && Prompt.confirm("\n\(current). Use \(preset.id) first?", default: true)) {
                if process["JEV_HOST"] != nil || fileEnvironment.values["JEV_HOST"] != nil && updated["JEV_HOST"] == nil {
                    print("JEV_HOST is set in your environment or an env file; change it there to \(preset.id)")
                } else {
                    updated["JEV_HOST"] = HostCredentials.preferring(preset.id, over: updated["JEV_HOST"])
                }
            }
        }

        try store.write(updated)
        print("\nSaved \(preset.id) in the login keychain (\(store.service)).")
        Self.restartProxy()
        environment = JevEnvironment.load()
        let resolution = HostPresets.resolve(environment: environment)
        print("jev asks: \(resolution.hosts.isEmpty ? "no host" : resolution.hosts.map(\.id).joined(separator: " then "))")
    }

    /// The LaunchAgent's proxy read its environment at start; restart it to pick up the change.
    static func restartProxy() {
        if LaunchAgent().restart() { print("Restarted the background proxy (jev serve) to use it.") }
    }

    func choosePreset(interactive: Bool, stored: [String: String], environment: JevEnvironment) throws -> HostPreset? {
        if let host {
            guard let preset = HostPresets.preset(host.lowercased()) else {
                throw ValidationError("unknown host \(host) (known: \(HostPresets.all.map(\.id).joined(separator: ", ")))")
            }
            return preset
        }
        guard interactive else { return nil }
        let saved = Set(HostCredentials.storedHosts(stored).map(\.id))
        print("Jev picks the model for each prompt. Which host should jev ask it through?")
        for (index, preset) in HostPresets.all.enumerated() {
            let configured = (try? HostPresets.host(preset.id, environment: environment).get()) != nil
            let mark = saved.contains(preset.id) ? "  [saved]" : configured ? "  [set in env]" : ""
            print("  \(index + 1)) \(preset.id.padding(toLength: 11, withPad: " ", startingAt: 0)) \(preset.summary)\(mark)")
        }
        while true {
            guard let answer = Prompt.line("Host [1]: ") else { throw ExitCode(1) }
            if answer.isEmpty { return HostPresets.all[0] }
            if let number = Int(answer), HostPresets.all.indices.contains(number - 1) { return HostPresets.all[number - 1] }
            if let preset = HostPresets.preset(answer.lowercased()) { return preset }
            print("Enter a number from 1 to \(HostPresets.all.count), or a host id.")
        }
    }

    func answersFromFlags(_ preset: HostPreset) throws -> [String: String?] {
        var answers: [String: String?] = [:]
        for pair in values {
            guard let equals = pair.firstIndex(of: "=") else { throw ValidationError("--set takes VARIABLE=value, not \(pair)") }
            let key = String(pair[..<equals])
            guard let field = preset.setup.first(where: { $0.variable == key }) else {
                let known = preset.setup.filter { $0.kind != .secret }.map(\.variable).joined(separator: ", ")
                throw ValidationError("\(preset.id) doesn't use \(key) (it takes \(known))")
            }
            guard field.kind != .secret else {
                throw ValidationError("pass \(key) with --key-stdin, so it doesn't show up in `ps` or your shell history")
            }
            answers[key] = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        if keyStdin {
            guard let field = preset.secretField else { throw ValidationError("\(preset.id) has no key to read") }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw ValidationError("--key-stdin read nothing") }
            answers[field.variable] = key
        }
        return answers
    }

    /// One field's answer: nil keeps the saved value, "" removes it.
    func ask(_ field: SetupField, saved: String?, interactive: Bool) throws -> String? {
        guard interactive else {
            if saved == nil && !field.optional {
                throw ValidationError(field.kind == .secret ? "\(field.variable) is required: pass it with --key-stdin"
                                                            : "\(field.variable) is required: pass --set \(field.variable)=…")
            }
            return nil
        }
        if let help = field.help { print("  \(field.label): \(help)") }
        while true {
            let answer: String?
            switch field.kind {
            case .secret:
                answer = Prompt.secret("\(field.label) (hidden\(saved == nil ? "" : "; Enter keeps the saved one")): ")
            case .text:
                let hint = saved.map { " [\($0)\(field.optional ? "; - clears it" : "")]" } ?? ""
                answer = Prompt.line("\(field.label)\(hint): ")
            case .choice(let options):
                answer = Prompt.line("\(field.label) (\(options.joined(separator: ", ")))\(saved.map { " [\($0)]" } ?? ""): ")
            }
            guard let answer else { throw ExitCode(1) }
            if answer.isEmpty {
                if saved != nil || field.optional { return nil }
                print("  \(field.label) is required.")
                continue
            }
            if answer == "-" && field.optional && field.kind != .secret { return "" }
            if case .choice(let options) = field.kind, !options.contains(answer) {
                print("  Choose one of \(options.joined(separator: ", ")).")
                continue
            }
            return answer
        }
    }
}

/// Terminal prompts for `jev setup`. Secrets are read with echo off and never printed.
enum Prompt {
    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    static func line(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces)
    }

    static func secret(_ prompt: String) -> String? {
        fflush(stdout)
        var buffer = [CChar](repeating: 0, count: 4096)
        defer { buffer.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }
        #if canImport(Darwin)
        guard let read = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else { return nil }
        return String(cString: read).trimmingCharacters(in: .whitespaces)
        #else
        guard let read = getpass(prompt) else { return nil }
        return String(cString: read).trimmingCharacters(in: .whitespaces)
        #endif
    }

    static func confirm(_ question: String, default yes: Bool) -> Bool {
        guard let answer = line("\(question) [\(yes ? "Y/n" : "y/N")] ")?.lowercased() else { return false }
        return answer.isEmpty ? yes : answer.hasPrefix("y")
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the background proxy, which apps route through it, and the Jev host.",
        discussion: "Exits non-zero when an app is routed to a proxy that isn't listening. `jev doctor` checks more.")

    func run() throws {
        let agent = LaunchAgent()
        let agentStatus = agent.status()
        let port = agentStatus.port ?? AppsManager.defaultPort
        let listening = ProxyProbe.isListening(port: port)
        let apps = try AppsManager().status()
        let width = max(12, apps.map(\.app.displayName.count).max() ?? 0)
        func line(_ label: String, _ value: String) { print("\(label.padding(toLength: width, withPad: " ", startingAt: 0))  \(value)") }

        let how: String
        if agentStatus.installed {
            how = agentStatus.pid.map { "LaunchAgent, pid \($0)" } ?? (agentStatus.loaded ? "LaunchAgent, not running" : "LaunchAgent, not loaded")
        } else {
            how = "no LaunchAgent (`jev serve install`)"
        }
        line("proxy", "\(listening ? "listening" : "not listening") on 127.0.0.1:\(port) (\(how))")
        if let executable = agentStatus.executable, !FileManager.default.isExecutableFile(atPath: executable) {
            line("", "\(executable) is missing; run `jev serve install`")
        }

        var problem = false
        for status in apps {
            guard status.enabled else {
                line(status.app.displayName, "not routed (`jev apps enable`)")
                continue
            }
            let up = status.port.map { ProxyProbe.isListening(port: $0) } ?? false
            if !up { problem = true }
            var value = "routed to \(status.baseURL ?? "?")"
            if status.defaultProvider == false { value += ", jev not the default provider" }
            if !up { value += ", NOTHING LISTENING: new sessions fail (`jev serve install` or `jev apps disable`)" }
            line(status.app.displayName, value)
        }

        let environment = JevEnvironment.load()
        let resolution = HostPresets.resolve(environment: environment)
        if resolution.hosts.isEmpty {
            line("Jev host", "none (\(resolution.source)); run `jev setup`")
        } else {
            let fromKeychain = resolution.hosts.contains { host in
                HostPresets.preset(host.id)?.setup.contains { environment.storedKeys.contains($0.variable) } ?? false
            }
            line("Jev host", resolution.hosts.map(\.id).joined(separator: " then ") + (fromKeychain ? " (keychain)" : " (\(resolution.source))"))
        }
        for hostProblem in resolution.problems { line("", hostProblem.description) }
        if let credentialProblem = environment.credentialProblem { line("keychain", credentialProblem) }

        let week = UsageLedger.standard(environment: environment.values).records(since: Date().addingTimeInterval(-7 * 86_400))
        let savings = SavingsReport(records: week, prices: PriceTable.load(environment: environment.values).table)
        line("savings", savings.turns == 0 ? "no turns recorded in the last 7 days" : "\(savings.summary) in the last 7 days (`jev savings`)")
        if problem { throw ExitCode(1) }
    }
}
