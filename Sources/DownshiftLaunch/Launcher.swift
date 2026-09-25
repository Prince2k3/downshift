import Foundation
import DownshiftCore
import DownshiftProxy
import Logging
import ServiceLifecycle

/// Sends the proxy's swift-log output through `DownshiftLog`, which writes to a file while a TUI
/// owns the terminal: a line printed under Claude Code or Codex would be drawn over.
public struct DownshiftLogHandler: LogHandler {
    let log: DownshiftLog
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level

    public init(log: DownshiftLog) {
        self.log = log
        logLevel = log.debugEnabled ? .debug : .notice
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        var line = "\(event.level): \(event.message)"
        // Metadata only while debugging; it is request paths and ids, never headers or bodies.
        if log.debugEnabled {
            let merged = metadata.merging(event.metadata ?? [:]) { $1 }
            if !merged.isEmpty {
                line += " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            }
        }
        log.log(line)
    }
}

/// Runs an agent CLI behind a per-launch proxy (plan §5, §5b): the proxy on an ephemeral
/// loopback port, the child once the port is bound, and `cleanup` after the proxy drains.
public enum Launcher {
    public struct Child: Sendable {
        public var executable: String
        public var arguments: @Sendable (_ port: Int) -> [String]
        public var environment: @Sendable (_ port: Int) -> [String: String]

        public init(executable: String, arguments: @escaping @Sendable (Int) -> [String],
                    environment: @escaping @Sendable (Int) -> [String: String]) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
        }
    }

    /// Returns how the child ended; nil if it never started (the proxy failed first).
    public static func run(_ configuration: ProxyServer.Configuration, child: Child, logger: Logger,
                           cleanup: @escaping @Sendable () async -> Void) async throws -> Termination? {
        // The terminal sends Ctrl-C and Ctrl-\ to the whole foreground group; the TUI handles
        // them and the launcher waits for it to exit. The child gets default dispositions back.
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        let gate = PortGate()
        let service = ChildProcessService {
            let port = try await gate.wait()
            return try ChildProcess.spawn(child.executable, arguments: child.arguments(port),
                                          environment: child.environment(port))
        }
        try await ProxyServer.run(configuration, logger: logger, cleanup: CleanupService(cleanup), child: service,
                                  signals: [], onListening: { gate.open($0) })
        return service.termination
    }
}

/// The path the status line runs dshift by.
public enum DownshiftExecutable {
    /// The path dshift was invoked by, made absolute, symlinks kept (a Homebrew path survives upgrades).
    public static func path(invokedAs argument0: String = CommandLine.arguments[0],
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        resolvedInvocation(argument0, environment: environment)
    }

    static func resolvedInvocation(_ argument0: String, environment: [String: String]) -> String? {
        if argument0.contains("/") {
            let url = argument0.hasPrefix("/")
                ? URL(fileURLWithPath: argument0)
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent(argument0)
            return url.standardizedFileURL.path
        }
        return ExecutableResolver(environment: environment).onPath(argument0)
    }
}
