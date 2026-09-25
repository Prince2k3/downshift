import Foundation
import ServiceLifecycle
import UnixSignals

/// The agent CLI as a lifecycle service (plan §5b). It waits for `launch` (which waits for
/// the proxy's port), runs the child to completion and records how it ended. Its return,
/// or failure to start, shuts the group down gracefully, so the proxy drains and cleanup
/// runs after the child is gone.
///
/// SIGTERM and SIGHUP are forwarded to the child and the service keeps waiting: the child
/// decides when to go. SIGINT and SIGQUIT are the launcher's to ignore (the terminal sends
/// them to the whole foreground group, the child included).
public final class ChildProcessService: Service, Sendable {
    public typealias Launch = @Sendable () async throws -> ChildProcess

    let launch: Launch
    let forwarded: [UnixSignal]
    private let state = Locked<Termination?>(nil)

    public init(forwarding forwarded: [UnixSignal] = [.sigterm, .sighup], launch: @escaping Launch) {
        self.launch = launch
        self.forwarded = forwarded
    }

    /// Nil until the child has exited (and if it never started).
    public var termination: Termination? { state.value }

    public func run() async throws {
        let child = try await launch()
        let signals = await UnixSignalsSequence(trapping: forwarded)
        let ended = await withTaskGroup(of: Termination?.self) { group in
            group.addTask {
                for await signal in signals { child.send(signal.rawValue) }
                return nil
            }
            group.addTask {
                // Another service failing, or a graceful shutdown from elsewhere, asks the
                // child to stop; its exit still ends this service.
                await withTaskCancellationHandler {
                    await withGracefulShutdownHandler {
                        await child.wait()
                    } onGracefulShutdown: {
                        child.send(SIGTERM)
                    }
                } onCancel: {
                    child.send(SIGTERM)
                }
            }
            var result: Termination?
            while let next = await group.next() {
                if let next {
                    result = next
                    group.cancelAll()
                }
            }
            return result
        }
        state.value = ended
    }
}

/// Runs `action` once the group shuts down: listed first, it stops last (after the proxy
/// has drained), and it also runs when the group is cancelled.
public struct CleanupService: Service {
    let action: @Sendable () async -> Void

    public init(_ action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    public func run() async throws {
        try? await gracefulShutdown()
        await action()
    }
}

/// Hands the proxy's bound port to whoever is waiting for it (the child's launch).
public final class PortGate: Sendable {
    private struct State {
        var port: Int?
        var waiters: [Int: CheckedContinuation<Int, any Error>] = [:]
        var next = 0
    }
    private let state = Locked(State())

    public init() {}

    public func open(_ port: Int) {
        let waiters = state.withLock { state -> [CheckedContinuation<Int, any Error>] in
            guard state.port == nil else { return [] }
            state.port = port
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume(returning: port) }
    }

    /// Throws `CancellationError` if cancelled first (the proxy failed to start).
    public func wait() async throws -> Int {
        let id = state.withLock { state -> Int in
            defer { state.next += 1 }
            return state.next
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> Int?? in
                    if let port = state.port { return .some(port) }
                    if Task.isCancelled { return .some(nil) }
                    state.waiters[id] = continuation
                    return .none
                }
                switch ready {
                case .some(.some(let port)): continuation.resume(returning: port)
                case .some(.none): continuation.resume(throwing: CancellationError())
                case .none: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&stored) }
    }
}
