import ArgumentParser
import Foundation
import DownshiftAgents
import DownshiftCore
import JevHosts
import DownshiftLaunch
import DownshiftProxy
import Logging

/// Options `dshift claude` and `dshift codex` take for themselves. They come before the agent's own
/// arguments; everything from the first argument dshift doesn't know is passed through untouched.
/// `--jev-model` and `--dshift-debug` are prefixed so they can't shadow the agents' `--model`/`--debug`.
struct LaunchOptions: ParsableArguments {
    @Option(help: "Jev host, or a comma-separated failover list (see `dshift hosts list`). Overrides DSHIFT_HOST; `none` turns routing off.")
    var host: String?
    @Option(name: .customLong("jev-model"), help: "Model the Jev host routes with (sets DSHIFT_MODEL).")
    var jevModel: String?
    @Flag(name: .customLong("dshift-debug"), help: "Log routing decisions (sets DSHIFT_DEBUG).")
    var jevDebug = false
    @Flag(name: .customLong("no-route"), help: "Keep the model you chose instead of routing; the proxy only passes traffic through.")
    var noRoute = false

    var route: Bool { !noRoute }

    func environment() -> DownshiftEnvironment {
        var environment = DownshiftEnvironment.load()
        if let jevModel { environment.values["DSHIFT_MODEL"] = jevModel }
        if jevDebug { environment.values["DSHIFT_DEBUG"] = "1" }
        return environment
    }
}

/// What both launchers share: the router, the log, and running the child behind the proxy.
enum LaunchSupport {
    /// Nil when there is no usable host: the proxy still runs and turns the sentinel into the
    /// baseline, so the session works, just without routing.
    static func router(host: String?, environment: DownshiftEnvironment, log: DownshiftLog) -> JevRouter? {
        let resolution = HostPresets.resolve(flag: host, environment: environment)
        for problem in resolution.problems { warn("jev host \(problem)") }
        guard !resolution.hosts.isEmpty else {
            warn("no Jev host (\(resolution.source)); this session stays on its starting model. Run `dshift setup`.")
            return nil
        }
        return JevRouting.router(JevClient(hosts: resolution.hosts, log: log))
    }

    static func logger(_ log: DownshiftLog) -> Logger {
        Logger(label: "dshift") { _ in DownshiftLogHandler(log: log) }
    }

    static func warn(_ line: String) {
        FileHandle.standardError.write(Data("dshift: \(line)\n".utf8))
    }

    /// The command the status line runs dshift with (absolute, since the session's PATH may
    /// not have dshift on it).
    static func dshiftCommand() -> String {
        ClaudeLaunch.command(executable: DownshiftExecutable.path() ?? CommandLine.arguments[0])
    }

    /// A 0700 folder under TMPDIR for this launcher's generated files. Fixed paths, rewritten
    /// each launch, so nothing piles up when a session is killed.
    static func scratchDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try AtomicFile.privateDirectory(directory)
        return directory
    }

    static func run(_ configuration: ProxyServer.Configuration, child: Launcher.Child, log: DownshiftLog,
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
              dshift claude                    interactive session
              dshift claude -p "fix the tests" print mode
              dshift claude --no-route ...     proxy only, no routing
            dshift's own options go before claude's.
            """
    )

    @OptionGroup var options: LaunchOptions
    @Flag(name: .customLong("no-statusline"), help: "Don't add dshift's status line (also DSHIFT_NO_STATUSLINE=1).")
    var noStatusline = false
    @Argument(parsing: .captureForPassthrough, help: "Arguments for claude.")
    var arguments: [String] = []

    func run() async throws {
        guard let claude = ExecutableResolver().claude() else {
            throw AppsError("Claude Code not found on PATH or in the Claude app; install it from https://claude.com/claude-code")
        }
        let environment = options.environment()
        let settings = DownshiftSettings(environment: environment)
        let log = DownshiftLog(settings: settings)
        let process = ProcessInfo.processInfo.environment
        let userSettings = AppsLocations.standard(environment: process).claudeSettings
        let settingsFiles = ClaudeLaunch.settingsFiles(
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), userSettings: userSettings)
        let subcommand = ClaudeLaunch.isSubcommand(arguments)
        let route = options.route && !subcommand

        // With `dshift apps enable --claude`, the sentinel is a legitimate saved model; otherwise
        // one left behind by a killed session would break plain `claude`, so put it back.
        let appsManaged = ClaudeSettingsEdit.isEnabled(try? Data(contentsOf: userSettings)) != nil
        let saved = ClaudeSettings.savedModel(in: userSettings)
        if !appsManaged && ClaudeSettings.restoreSavedModel(nil, in: userSettings) {
            log.log("removed a downshift model left in \(userSettings.path) by an earlier session")
        }

        let baselineModel = ClaudeLaunch.baselineModel(arguments: arguments, environment: process, settingsFiles: settingsFiles)
        let router = route ? LaunchSupport.router(host: options.host, environment: environment, log: log) : nil
        let engine = route
            ? RoutingEngine(baseline: baselineModel.flatMap(ClaudeModel.tier(of:)) ?? .balanced, baselineModel: baselineModel,
                            available: settings.availableTiers, router: router, store: StatusStore(), log: log,
                            ledger: UsageLedger.standard(environment: environment.values))
            : nil

        var statusLineFile: URL?
        let wantStatusLine = !subcommand && !noStatusline && settings.statusLine
            && !ClaudeLaunch.hasOwnStatusLine(settingsFiles: settingsFiles)
            && !ForwardedArguments.contains(["--settings"], in: arguments)
        if wantStatusLine {
            let file = try LaunchSupport.scratchDirectory("dshift-claude").appendingPathComponent("settings.json")
            try AtomicFile.write(ClaudeLaunch.statusLineSettings(command: LaunchSupport.dshiftCommand()), to: file, permissions: 0o600)
            statusLineFile = file
        }

        let forwarded = arguments
        let childArguments = ClaudeLaunch.arguments(forwarded, route: route, settingsFile: statusLineFile)
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
            ChatGPT.app) with a `dshift` provider pointing at it, starting on the model you would
            have had anyway (-m, the profile's model, or config.toml's).
              dshift codex                     interactive session
              dshift codex exec "fix the tests"
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
        let settings = DownshiftSettings(environment: environment)
        let log = DownshiftLog(settings: settings)
        let process = ProcessInfo.processInfo.environment
        let codexHome = AppsLocations.standard(environment: process).codexConfig.deletingLastPathComponent()
        let route = options.route

        let baselineModel = CodexLaunch.baselineModel(arguments: arguments, codexHome: codexHome)
        let adapter = CodexAdapter(environment: environment.values)
        let router = route ? LaunchSupport.router(host: options.host, environment: environment, log: log) : nil
        let engine = route
            ? RoutingEngine(adapter: adapter, baseline: baselineModel.flatMap(adapter.tier(of:)) ?? .strong,
                            baselineModel: baselineModel, available: settings.availableTiers, router: router,
                            store: nil, log: log,
                            ledger: UsageLedger.standard(environment: environment.values))
            : nil

        let forwarded = arguments
        let child = Launcher.Child(
            executable: codex.path,
            arguments: { port in
                CodexLaunch.arguments(forwarded, baseURL: AppsManager.baseURL(for: .codex, port: port), route: route)
            },
            environment: { _ in process })
        let configuration = ProxyServer.Configuration(port: 0, dumpDirectory: settings.dumpDirectory, codexEngine: engine)
        try await LaunchSupport.run(configuration, child: child, log: log)
    }
}
