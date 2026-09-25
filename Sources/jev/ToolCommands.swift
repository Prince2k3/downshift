import ArgumentParser
import Foundation
import JevAgents
import JevCore
import JevHosts
import JevLaunch

struct ExplainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Show why Jev picked the model for a session's last prompt (what /jev-explain runs).")

    @Argument(help: "Session id. Defaults to this Codex session (JEV_CODEX_STATUS_ID), then the most recent one.")
    var session: String?

    func run() throws {
        let store = StatusStore()
        let environment = ProcessInfo.processInfo.environment
        let id = [session, environment["JEV_CODEX_STATUS_ID"]].compactMap { $0 }.first { !$0.isEmpty }
            ?? store.latestSession()
        print(Explain.format(id.flatMap(store.read(session:))))
    }
}

struct StatuslineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statusline",
        abstract: "Print Claude Code's status line from the session JSON on stdin.",
        shouldDisplay: false)

    func run() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let input = (try? JSONValue.parse(data)) ?? .object(JSONObject())
        let session = input["session_id"]?.stringValue
        print(StatusLine.render(input: input, status: session.flatMap(StatusStore().read(session:))))
    }
}

struct SkillsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skills",
        abstract: "Install jev's agent skills (/jev-explain, $jev-explain) for a project or for your user.",
        discussion: """
            `jev claude` loads its skills by itself; install them to use them in plain `claude`,
            the Claude app, or Codex. Project installs run `jev` from PATH, so they can be committed.
            """,
        subcommands: [Install.self, List.self],
        defaultSubcommand: List.self)

    struct AgentSelection: ParsableArguments {
        @Flag(help: "Claude Code skills (.claude/skills).") var claude = false
        @Flag(help: "Codex skills (.agents/skills).") var codex = false

        var agents: [SkillAgent] {
            let chosen = SkillAgent.allCases.filter { ($0 == .claude && claude) || ($0 == .codex && codex) }
            return chosen.isEmpty ? SkillAgent.allCases : chosen
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write the skills into a project or your home folder.")

        @Flag(help: "Into a project (the current folder, or PATH).") var project = false
        @Flag(help: "Into your user skills folders.") var user = false
        @OptionGroup var selection: AgentSelection
        @Flag(help: "Replace skill files jev didn't write.") var force = false
        @Argument(help: "Project folder for --project.") var path: String?

        func validate() throws {
            guard project != user else { throw ValidationError("pass exactly one of --project or --user") }
            if user && path != nil { throw ValidationError("a folder only goes with --project") }
        }

        func run() throws {
            let command: String
            let root: URL?
            if project {
                command = SkillInstaller.command(executable: nil)
                root = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath, isDirectory: true)
            } else {
                command = LaunchSupport.jevCommand()
                root = nil
            }
            var skipped = false
            for agent in selection.agents {
                let directory = root.map { SkillInstaller.skillsDirectory(agent, root: $0) } ?? SkillInstaller.userSkillsDirectory(agent)
                for skill in Skill.all {
                    let file = SkillInstaller.file(skill, in: directory)
                    switch try SkillInstaller.install(skill, agent: agent, command: command, in: directory, force: force) {
                    case .written: print("wrote      \(file.path)")
                    case .unchanged: print("up to date \(file.path)")
                    case .skippedForeign:
                        print("skipped    \(file.path) (not jev's; --force replaces it)")
                        skipped = true
                    }
                }
            }
            if skipped { throw ExitCode(1) }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which skills are installed for your user and this folder.")

        func run() {
            let userCommand = LaunchSupport.jevCommand()
            let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            for agent in SkillAgent.allCases {
                for skill in Skill.all {
                    let places: [(String, URL, String)] = [
                        ("user", SkillInstaller.userSkillsDirectory(agent), userCommand),
                        ("project", SkillInstaller.skillsDirectory(agent, root: here), SkillInstaller.command(executable: nil)),
                    ]
                    for (scope, directory, command) in places {
                        let state = SkillInstaller.state(skill, agent: agent, command: command, in: directory)
                        let label = switch state {
                        case .missing: "not installed"
                        case .current: "installed"
                        case .outdated: "outdated (run `jev skills install --\(scope)`)"
                        case .foreign: "someone else's file"
                        }
                        let name = agent == .claude ? "/\(skill.name)" : "$\(skill.name)"
                        print("\(agent.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(scope.padding(toLength: 8, withPad: " ", startingAt: 0)) \(label)")
                        if state != .missing { print("        \(SkillInstaller.file(skill, in: directory).path)") }
                    }
                }
            }
        }
    }
}

/// What `jev doctor` knows about the installed agents. Reads files only;
/// nothing is executed.
struct AgentInventory {
    struct Line {
        var label: String
        var value: String
    }

    var lines: [Line] = []
    var claudeFound = false
    var codexFound = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let resolver = ExecutableResolver(environment: environment)
        let locations = AppsLocations.standard(environment: environment)
        if let claude = resolver.claude() {
            claudeFound = true
            let version = Self.cliVersion(claude.path).map { " \($0)" } ?? ""
            lines.append(Line(label: "claude", value: "\(claude.path)\(version) (\(claude.source.rawValue))"))
        } else {
            lines.append(Line(label: "claude", value: "not found (PATH or Claude app)"))
        }
        if let app = Self.appVersion("Claude.app", in: resolver.applications) {
            let bundled = Self.bundledClaudeVersions(home: resolver.home)
            lines.append(Line(label: "Claude.app", value: app + (bundled.isEmpty ? "" : ", Claude Code \(bundled.joined(separator: ", "))")))
        }
        let claudeData = try? Data(contentsOf: locations.claudeSettings)
        let routed = ClaudeSettingsEdit.isEnabled(claudeData).map { "routed via \($0)" } ?? "not routed"
        lines.append(Line(label: "  settings", value: "\(locations.claudeSettings.path) (\(claudeData == nil ? "absent" : routed))"))

        if let codex = resolver.codex() {
            codexFound = true
            lines.append(Line(label: "codex", value: "\(codex.path) (\(codex.source.rawValue))"))
        } else {
            lines.append(Line(label: "codex", value: "not found (PATH or ChatGPT.app)"))
        }
        if let app = Self.appVersion("ChatGPT.app", in: resolver.applications) {
            lines.append(Line(label: "ChatGPT.app", value: app))
        }
        let codexData = try? Data(contentsOf: locations.codexConfig)
        let codexRouted = CodexConfigEdit.isEnabled(codexData) ? "routed via jev provider" : "not routed"
        lines.append(Line(label: "  config", value: "\(locations.codexConfig.path) (\(codexData == nil ? "absent" : codexRouted))"))
    }

    /// Claude Code's installer links `claude` to `…/versions/<version>`.
    static func cliVersion(_ path: String) -> String? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard target.deletingLastPathComponent().lastPathComponent == "versions" else { return nil }
        return target.lastPathComponent
    }

    static func appVersion(_ name: String, in folders: [URL]) -> String? {
        for folder in folders {
            let plist = folder.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            let version = info["CFBundleShortVersionString"] as? String ?? "?"
            return "\(folder.appendingPathComponent(name).path) \(version)"
        }
        return nil
    }

    static func bundledClaudeVersions(home: URL) -> [String] {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func printed() {
        for line in lines { print("\(line.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(line.value)") }
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check the agents, the Jev host, and the proxy setup.")

    @Option(help: "Jev host to check instead of JEV_HOST.") var host: String?

    func run() throws {
        var failed = false
        func report(_ ok: Bool?, _ label: String, _ detail: String) {
            let mark = switch ok {
            case .some(true): "ok  "
            case .some(false): "FAIL"
            case .none: "warn"
            }
            if ok == false { failed = true }
            print("\(mark) \(label.count < 12 ? label.padding(toLength: 12, withPad: " ", startingAt: 0) : label) \(detail)")
        }

        let inventory = AgentInventory()
        inventory.printed()
        print("")
        report(inventory.claudeFound || inventory.codexFound, "agents",
               inventory.claudeFound || inventory.codexFound ? "found" : "neither claude nor codex found")

        // Host resolution only: ids and sources, never keys.
        let environment = JevEnvironment.load()
        let resolution = HostPresets.resolve(flag: host, environment: environment)
        if resolution.hosts.isEmpty {
            report(nil, "Jev host", "none (\(resolution.source)); sessions stay on their starting model. Run `jev setup`")
        } else {
            report(true, "Jev host", "\(resolution.hosts.map(\.id).joined(separator: " then ")) (\(resolution.source))")
        }
        for problem in resolution.problems { report(false, "Jev host", problem.description) }
        if let problem = environment.credentialProblem { report(false, "keychain", problem) }
        if !environment.loadedFiles.isEmpty {
            print("     env files    \(environment.loadedFiles.map(\.path).joined(separator: ", "))")
        }

        let statusDirectory = StatusStore().directory
        if let attributes = try? FileManager.default.attributesOfItem(atPath: statusDirectory.path) {
            let mode = (attributes[.posixPermissions] as? Int ?? 0) & 0o777
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            let ok = mode == 0o700 && owner == getuid()
            report(ok, "status dir", "\(statusDirectory.path) (\(String(mode, radix: 8))\(owner == getuid() ? "" : ", not yours"))")
        } else {
            report(true, "status dir", "\(statusDirectory.path) (created on first use)")
        }

        let locations = AppsLocations.standard()
        let claudeData = try? Data(contentsOf: locations.claudeSettings)
        if ClaudeSettingsEdit.isEnabled(claudeData) == nil,
           let data = claudeData, let root = try? JSONValue.parse(data), RouterModel.isRouted(root["model"]?.stringValue) {
            report(false, "saved model", "\(locations.claudeSettings.path) saves `\(RouterModel.id)`, which plain `claude` can't use; `jev claude` repairs it on launch")
        }

        let agent = LaunchAgent()
        let agentStatus = agent.status()
        for status in (try? AppsManager().status()) ?? [] where status.enabled {
            let listening = status.port.map { ProxyProbe.isListening(port: $0) } ?? false
            report(listening, status.app.displayName,
                   "routed to port \(status.port.map(String.init) ?? "?")\(listening ? ", proxy listening" : ", nothing listening (`jev serve install`)")")
        }
        if agentStatus.installed {
            let running = agentStatus.loaded && agentStatus.pid != nil
            report(running, "LaunchAgent", running ? "running (pid \(agentStatus.pid!))" : "installed but not running")
            if let executable = agentStatus.executable, !FileManager.default.isExecutableFile(atPath: executable) {
                report(false, "LaunchAgent", "\(executable) is missing; run `jev serve install`")
            }
        } else {
            report(nil, "LaunchAgent", "not installed (only needed for `jev apps`)")
        }
        if failed { throw ExitCode(1) }
    }
}
