import ArgumentParser
import Foundation
import JevAgents
import JevCore
import JevHosts
import JevProxy
import Logging

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the persistent proxy the desktop apps use, in the foreground or as a LaunchAgent.",
        discussion: """
            `jev apps enable` points the apps at 127.0.0.1:\(AppsManager.defaultPort); this is what listens there.
              jev serve                 run in the foreground (Ctrl-C to stop)
              jev serve install         run it at login and keep it running (LaunchAgent)
              jev serve uninstall       stop it and remove the LaunchAgent
            """,
        subcommands: [Run.self, Install.self, Uninstall.self],
        defaultSubcommand: Run.self
    )

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run the proxy in the foreground.")

        @Option(help: "Port on 127.0.0.1.") var port = AppsManager.defaultPort
        @Option(help: "Upstream for Claude traffic.") var upstream = ProxyServer.claudeUpstream
        @Option(help: "Upstream for Codex traffic, served under /codex. Empty disables it.")
        var codexUpstream = ProxyServer.codexUpstream
        @Option(help: "Jev host, or a comma-separated failover list (see `jev hosts list`). Overrides JEV_HOST; `none` turns routing off.")
        var host: String?
        @Flag(help: "Log every proxied request.") var debug = false

        func run() async throws {
            if ProxyProbe.isListening(port: port) {
                throw AppsError("something is already listening on 127.0.0.1:\(port) (the LaunchAgent? see `jev status`)")
            }
            Self.trimLogIfLarge()
            var logger = Logger(label: "jev")
            logger.logLevel = debug ? .debug : .info
            let environment = JevEnvironment.load()
            let settings = JevSettings(environment: environment)
            // Plan §5a: new conversations start on the model the user would have had without
            // jev. The apps don't pass --model, so that is the saved Claude Code model.
            let baseline = ClaudeSettings.savedModel().flatMap(ClaudeModel.tier(of:)) ?? .balanced
            let log = JevLog(destination: .standardError, debugEnabled: debug)
            // Without a host, routing fails open to the baseline, which still turns the
            // sentinel into a real model.
            let resolution = HostPresets.resolve(flag: host, environment: environment)
            for problem in resolution.problems { logger.warning("jev host \(problem)") }
            let router: JevRouter?
            if resolution.hosts.isEmpty {
                logger.warning("no Jev host (\(resolution.source)); every conversation stays on its model. Run `jev setup`.")
                router = nil
            } else {
                logger.info("Jev via \(resolution.hosts.map(\.id).joined(separator: " then ")) (\(resolution.source))")
                router = JevRouting.router(JevClient(hosts: resolution.hosts, log: log))
            }
            let ledger = UsageLedger.standard(environment: environment.values)
            let engine = RoutingEngine(baseline: baseline, available: settings.availableTiers, router: router,
                                       store: StatusStore(), log: log, ledger: ledger)
            // Codex starts on the model in config.toml (read only), when the catalog has it.
            let codexConfig = AppsLocations.standard(environment: environment.values).codexConfig
            let codexModel = CodexConfigEdit.topLevelString(try? Data(contentsOf: codexConfig), key: "model")
            let codexAdapter = CodexAdapter(environment: environment.values)
            let codexEngine = RoutingEngine(adapter: codexAdapter,
                                            baseline: codexModel.flatMap(codexAdapter.tier(of:)) ?? .strong,
                                            baselineModel: codexModel, available: settings.availableTiers,
                                            router: router, store: StatusStore(), log: log, ledger: ledger)
            let configuration = ProxyServer.Configuration(port: port, upstream: upstream, codexUpstream: codexUpstream,
                                                          claudeEngine: engine, codexEngine: codexEngine)
            try await ProxyServer.run(configuration, logger: logger) { [logger] bound in
                logger.info("jev serve listening on http://127.0.0.1:\(bound)")
            }
        }

        /// Under launchd, stderr is the append-only log file and nothing rotates it. Start
        /// it over when it passes 8 MiB; each (re)start is a natural point to do that.
        static func trimLogIfLarge() {
            var info = stat()
            guard fstat(STDERR_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 8 << 20 else { return }
            _ = ftruncate(STDERR_FILENO, 0)
            _ = lseek(STDOUT_FILENO, 0, SEEK_SET)
            _ = lseek(STDERR_FILENO, 0, SEEK_SET)
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install and start the LaunchAgent (runs at login, restarts if it exits).")

        @Option(help: "Port on 127.0.0.1.") var port = AppsManager.defaultPort

        func run() throws {
            guard let executable = LaunchAgent.executablePath(invokedAs: CommandLine.arguments[0]) else {
                throw AppsError("can't tell where the jev executable is; run it by its full path")
            }
            let agent = LaunchAgent()
            let outcome = try agent.install(executable: executable, port: port)
            let runs = agent.status().executable ?? executable
            switch outcome {
            case .alreadyInstalled: print("LaunchAgent already installed and loaded")
            case .installed: print("LaunchAgent installed")
            case .replaced: print("LaunchAgent updated and reloaded")
            }
            print("  plist    \(agent.plistURL.path)")
            print("  runs     \(LaunchAgent.programArguments(executable: runs, port: port).joined(separator: " "))")
            print("  log      \(agent.logURL.path)")
            if LaunchAgent.isDevelopmentBuild(executable) {
                print("  note     development build copied from \(executable); run `jev serve install` again after rebuilding")
            }

            if waitUntilListening(port: port) {
                print("  proxy    listening on 127.0.0.1:\(port)")
            } else {
                print("  proxy    NOT listening on 127.0.0.1:\(port) yet; check the log above")
                throw ExitCode(1)
            }
            for status in (try? AppsManager().status()) ?? [] where status.enabled && status.port != port {
                print("warning: \(status.app.displayName) points at port \(status.port ?? 0), not \(port)")
            }
        }

        /// A freshly built binary's first launch can take several seconds while macOS assesses it.
        func waitUntilListening(port: Int) -> Bool {
            for _ in 0..<150 {
                if ProxyProbe.isListening(port: port) { return true }
                usleep(100_000)
            }
            return false
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the proxy and remove the LaunchAgent.")

        @Flag(help: "Remove it even though apps are still routed through it (their new sessions will fail).")
        var force = false

        func run() throws {
            let agent = LaunchAgent()
            let port = agent.status().port
            let routed = (try AppsManager().status()).filter { $0.enabled && (port == nil || $0.port == port) }
            if !routed.isEmpty && !force {
                let names = routed.map(\.app.displayName).joined(separator: ", ")
                throw AppsError("\(names) still route through the proxy, and would fail without it. Run `jev apps disable` first, or pass --force.")
            }
            if try agent.uninstall() {
                print("LaunchAgent stopped and removed (\(agent.plistURL.path))")
            } else {
                print("LaunchAgent not installed")
            }
        }
    }
}
