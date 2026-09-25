import Foundation

/// How a child process ended.
public enum Termination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    /// What the launcher exits with: the child's own code, or 128+signal (plan §5).
    public var exitCode: Int32 {
        switch self {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
    }
}

public struct SpawnError: Error, CustomStringConvertible {
    public var executable: String
    public var code: Int32
    public var description: String { "could not start \(executable): \(String(cString: strerror(code)))" }
}

/// A child sharing the terminal: stdin, stdout and stderr are inherited, it stays in the
/// foreground process group (so Ctrl-C reaches it straight from the terminal), and every
/// other descriptor is closed, so the proxy's listening socket never leaks into the agent.
///
/// The parent ignores SIGINT and SIGQUIT while the child runs, so the child is spawned with
/// every signal back at its default disposition and an empty mask; otherwise it would
/// inherit the ignored signals and Ctrl-C would stop working in the TUI.
public final class ChildProcess: Sendable {
    public let pid: pid_t
    public let executable: String

    private init(pid: pid_t, executable: String) {
        self.pid = pid
        self.executable = executable
    }

    public static func spawn(_ executable: String, arguments: [String], environment: [String: String]) throws -> ChildProcess {
        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        #else
        var attributes = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var flags = Int32(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))

        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        #if canImport(Darwin)
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        #endif

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw SpawnError(executable: executable, code: result) }
        return ChildProcess(pid: pid, executable: executable)
    }

    /// Waits on a thread of its own, so a long-running TUI never holds a cooperative thread.
    /// Only one caller may wait.
    public func wait() async -> Termination {
        let pid = pid
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 {
                    if errno != EINTR {
                        continuation.resume(returning: .exited(127))
                        return
                    }
                }
                continuation.resume(returning: Self.termination(status))
            }
        }
    }

    public func send(_ signal: Int32) {
        kill(pid, signal)
    }

    static func termination(_ status: Int32) -> Termination {
        // The WIFEXITED/WTERMSIG macros aren't imported into Swift.
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }
}
