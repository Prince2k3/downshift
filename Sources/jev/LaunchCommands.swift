import ArgumentParser
import Foundation
import JevAgents
import JevCore
import JevHosts
import JevLaunch
import JevProxy
import Logging

/// Options `jev claude` and `jev codex` take for themselves. They come before the agent's own
/// arguments; everything from the first argument jev doesn't know is passed through untouched.
/// `--jev-model` and `--jev-debug` are prefixed so they can't shadow the agents' `--model`/`--debug`.
struct LaunchOptions: ParsableArguments {
    @Option(help: "Jev host, or a comma-separated failover list (see `jev hosts list`). Overrides JEV_HOST; `none` turns routing off.")
    var host: String?
    @Option(name: .customLong("jev-model"), help: "Model the Jev host routes with (sets JEV_MODEL).")
    var jevModel: String?
    @Flag(name: .customLong("jev-debug"), help: "Log routing decisions (sets JEV_DEBUG).")
    var jevDebug = false
    @Flag(name: .customLong("no-route"), help: "Keep the model you chose instead of routing; the proxy only passes traffic through.")
    var noRoute = false

    var route: Bool { !noRoute }

    func environment() -> JevEnvironment {
        var environment = JevEnvironment.load()
        if let jevModel { environment.values["JEV_MODEL"] = jevModel }
        if jevDebug { environment.values["JEV_DEBUG"] = "1" }
        return environment
    }
}

/// What both launchers share: the router, the log, and running the child behind the proxy.
enum LaunchSupport {
    /// Nil when there is no usable host: the proxy still runs and turns the sentinel into the
    /// baseline, so the session works, just without routing.
    static func router(host: String?, environment: JevEnvironment, log: JevLog) -> JevRouter? {
        let resolution = HostPresets.resolve(flag: host, environment: environment)
        for problem in resolution.problems { warn("jev host \(problem)") }
        guard !resolution.hosts.isEmpty else {
            warn("no Jev host (\(resolution.source)); this session stays on its starting model. Run `jev setup`.")
            return nil
        }
        return JevRouting.router(JevClient(hosts: resolution.hosts, log: log))
    }

    static func logger(_ log: JevLog) -> Logger {
        Logger(label: "jev") { _ in JevLogHandler(log: log) }
    }

    static func warn(_ line: String) {
        FileHandle.standardError.write(Data("jev: \(line)\n".utf8))
    }

    /// The command skills and the status line run jev with (absolute, since the session's
    /// PATH may not have jev on it).
    static func jevCommand() -> String {
        SkillInstaller.command(executable: JevExecutable.path() ?? CommandLine.arguments[0])
    }

    /// A 0700 folder under TMPDIR for this launcher's generated files. Fixed paths, rewritten
    /// each launch, so nothing piles up when a session is killed.
    static func scratchDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try AtomicFile.privateDirectory(directory)
        return directory
    }

    static func run(_ configuration: ProxyServer.Configuration, child: Launcher.Child, log: JevLog,
                    cleanup: @escaping @Sendable () async -> Void = {}) async throws -> Never {
        let termination: Termination?
        do {
            termination = try await Launcher.run(configuration, child: child, logger: logger(log), cleanup: cleanup)
        } catch let error as SpawnError {
            await cleanup()
            throw AppsError(error.description)
        }
        guard let termination else { throw AppsError("the proxy stopped before \(child.executable) started") }
        throw ExitCode(termination.exitCode)
    }
}

struct ClaudeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude",
        abstract: "Run Claude Code with every prompt routed by Jev.",
        discussion: """
            Starts a private proxy on 127.0.0.1, then runs `claude` with the arguments you give,
            starting on the model you would have had anyway (--model, ANTHROPIC_MODEL, or the
            saved one). Pick \"\(ClaudeSettingsEdit.pickerName)\" in /model to route again after choosing a model.
              jev claude                    interactive session
              jev claude -p "fix the tests" print mode
              jev claude --no-route ...     proxy only, no routing
            jev's own options go before claude's.
            `/jev-explain` shows why the last prompt got its model.
            """
    )

    @OptionGroup var options: LaunchOptions
    @Flag(name: .customLong("no-statusline"), help: "Don't add jev's status line (also JEV_NO_STATUSLINE=1).")
    var noStatusline = false
    @Argument(parsing: .captureForPassthrough, help: "Arguments for claude.")
    var arguments: [String] = []

    func run() async throws {
        guard let claude = ExecutableResolver().claude() else {
            throw AppsError("Claude Code not found on PATH or in the Claude app; install it from https://claude.com/claude-code")
        }
        let environment = options.environment()
        let settings = JevSettings(environment: environment)
        let log = JevLog(settings: settings)
        let process = ProcessInfo.processInfo.environment
        let userSettings = AppsLocations.standard(environment: process).claudeSettings
        let settingsFiles = ClaudeLaunch.settingsFiles(
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), userSettings: userSettings)
        let subcommand = ClaudeLaunch.isSubcommand(arguments)
        let route = options.route && !subcommand

        // With `jev apps enable --claude`, the sentinel is a legitimate saved model; otherwise
        // one left behind by a killed session would break plain `claude`, so put it back.
        let appsManaged = ClaudeSettingsEdit.isEnabled(try? Data(contentsOf: userSettings)) != nil
        let saved = ClaudeSettings.savedModel(in: userSettings)
        if !appsManaged && ClaudeSettings.restoreSavedModel(nil, in: userSettings) {
            log.log("removed a jev-router model left in \(userSettings.path) by an earlier session")
        }

        let baselineModel = ClaudeLaunch.baselineModel(arguments: arguments, environment: process, settingsFiles: settingsFiles)
        let router = route ? LaunchSupport.router(host: options.host, environment: environment, log: log) : nil
        let engine = route
            ? RoutingEngine(baseline: baselineModel.flatMap(ClaudeModel.tier(of:)) ?? .balanced, baselineModel: baselineModel,
                            available: settings.availableTiers, router: router, store: StatusStore(), log: log,
                            ledger: UsageLedger.standard(environment: environment.values))
            : nil

        var skillRoot: URL?
        var statusLineFile: URL?
        if !subcommand {
            let scratch = try LaunchSupport.scratchDirectory("jev-claude")
            let command = LaunchSupport.jevCommand()
            let root = scratch.appendingPathComponent("skill-root", isDirectory: true)
            for skill in Skill.all {
                try SkillInstaller.install(skill, agent: .claude, command: command,
                                           in: SkillInstaller.skillsDirectory(.claude, root: root), force: true)
            }
            skillRoot = root
            let wantStatusLine = !noStatusline && settings.statusLine
                && !ClaudeLaunch.hasOwnStatusLine(settingsFiles: settingsFiles)
                && !ForwardedArguments.contains(["--settings"], in: arguments)
            if wantStatusLine {
                let file = scratch.appendingPathComponent("settings.json")
                try AtomicFile.write(ClaudeLaunch.statusLineSettings(command: command), to: file, permissions: 0o600)
                statusLineFile = file
            }
        }

        let forwarded = arguments
        let childArguments = ClaudeLaunch.arguments(forwarded, route: route, skillRoot: skillRoot, settingsFile: statusLineFile)
        let child = Launcher.Child(
            executable: claude.path,
            arguments: { _ in childArguments },
            environment: { port in
                ClaudeLaunch.environment(process, baseURL: AppsManager.baseURL(for: .claude, port: port), route: route)
            })
        let configuration = ProxyServer.Configuration(port: 0, codexUpstream: "", dumpDirectory: settings.dumpDirectory,
                                                      claudeEngine: engine)
        try await LaunchSupport.run(configuration, child: child, log: log) {
            // Choosing the picker row with Enter saves the sentinel as the default model.
            if !appsManaged && ClaudeSettings.restoreSavedModel(saved, in: userSettings) {
                log.log("restored the saved model in \(userSettings.path)")
            }
        }
    }
}

struct CodexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codex",
        abstract: "Run the Codex CLI with every prompt routed by Jev.",
        discussion: """
            Starts a private proxy on 127.0.0.1 and runs `codex` (from PATH, or the copy inside
            ChatGPT.app) with a `jev` provider pointing at it, starting on the model you would
            have had anyway (-m, the profile's model, or config.toml's).
              jev codex                     interactive session
              jev codex exec "fix the tests"
            `$jev-explain` shows why the last prompt got its model.
            """
    )

    @OptionGroup var options: LaunchOptions
    @Argument(parsing: .captureForPassthrough, help: "Arguments for codex.")
    var arguments: [String] = []

    func run() async throws {
        guard let codex = ExecutableResolver().codex() else {
            throw AppsError("Codex not found on PATH or in ChatGPT.app; install it with `brew install codex`")
        }
        let environment = options.environment()
        let settings = JevSettings(environment: environment)
        let log = JevLog(settings: settings)
        let process = ProcessInfo.processInfo.environment
        let codexHome = AppsLocations.standard(environment: process).codexConfig.deletingLastPathComponent()
        let route = options.route
        let statusID = CodexLaunch.statusID()

        let baselineModel = CodexLaunch.baselineModel(arguments: arguments, codexHome: codexHome)
        let adapter = CodexAdapter(environment: environment.values)
        let router = route ? LaunchSupport.router(host: options.host, environment: environment, log: log) : nil
        let engine = route
            ? RoutingEngine(adapter: adapter, baseline: baselineModel.flatMap(adapter.tier(of:)) ?? .strong,
                            baselineModel: baselineModel, available: settings.availableTiers, router: router,
                            store: StatusStore(), statusSession: statusID, log: log,
                            ledger: UsageLedger.standard(environment: environment.values))
            : nil

        installSkill(log: log)

        let forwarded = arguments
        let child = Launcher.Child(
            executable: codex.path,
            arguments: { port in
                CodexLaunch.arguments(forwarded, baseURL: AppsManager.baseURL(for: .codex, port: port), route: route)
            },
            environment: { _ in
                var environment = process
                environment["JEV_CODEX_STATUS_ID"] = statusID
                return environment
            })
        let configuration = ProxyServer.Configuration(port: 0, dumpDirectory: settings.dumpDirectory, codexEngine: engine)
        try await LaunchSupport.run(configuration, child: child, log: log)
    }

    /// Codex has no per-launch skill folder, so `$jev-explain` goes in the user's. The Node
    /// version's `jev-router-explain` is replaced when it is jev's.
    func installSkill(log: JevLog) {
        let directory = SkillInstaller.userSkillsDirectory(.codex)
        let command = LaunchSupport.jevCommand()
        for skill in Skill.all {
            do {
                if try SkillInstaller.install(skill, agent: .codex, command: command, in: directory) == .skippedForeign {
                    LaunchSupport.warn("\(SkillInstaller.file(skill, in: directory).path) isn't jev's; $\(skill.name) not installed")
                }
            } catch {
                log.log("could not install $\(skill.name): \(error)")
            }
        }
        let legacy = directory.appendingPathComponent("jev-router-explain", isDirectory: true)
        if let text = try? String(contentsOf: legacy.appendingPathComponent("SKILL.md"), encoding: .utf8),
           text.contains("<jev-explain>") {
            try? FileManager.default.removeItem(at: legacy.appendingPathComponent("SKILL.md"))
            _ = rmdir(legacy.path) // leaves the folder if anything else is in it
        }
    }
}
