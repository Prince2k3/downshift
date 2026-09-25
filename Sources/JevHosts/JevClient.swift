import AsyncHTTPClient
import Foundation
import DownshiftCore
import NIOCore

/// Asks Jev through one or more hosts, within a hard deadline. It never throws: any failure
/// comes back as an outcome without a result, and routing then keeps the current model.
/// Request and reply bodies contain the user's prompt, so nothing here logs them.
public struct JevClient: Sendable {
    public struct Timing: Sendable {
        public var attemptTimeout: Duration
        /// Extra attempts per host after the first, for timeouts, transport errors, 408, 429 and 5xx.
        public var retries: Int
        public var backoffInitial: Duration
        public var backoffMax: Duration
        /// Bounds everything, including failover to later hosts.
        public var deadline: Duration

        public init(attemptTimeout: Duration = .milliseconds(1500), retries: Int = 1,
                    backoffInitial: Duration = .milliseconds(150), backoffMax: Duration = .milliseconds(400),
                    deadline: Duration = .seconds(3)) {
            self.attemptTimeout = attemptTimeout
            self.retries = retries
            self.backoffInitial = backoffInitial
            self.backoffMax = backoffMax
            self.deadline = deadline
        }
    }

    /// Replies larger than this are not Jev answers.
    public static let maxReply = 4 << 20

    /// A client for Jev calls that is never shut down, so it can live for the whole process.
    /// Redirects are refused so a redirect cannot carry the bearer token to another host.
    public static let sharedHTTPClient: HTTPClient = {
        var configuration = HTTPClient.Configuration(redirectConfiguration: .disallow)
        configuration.timeout.connect = .milliseconds(1500)
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }()

    public let hosts: [JevHost]
    let http: HTTPClient
    let timing: Timing
    let log: DownshiftLog?
    /// Keep each reply body on its attempt, for `dshift hosts test`. Never set this in `serve`:
    /// replies can quote the prompt.
    let keepReplies: Bool

    public init(hosts: [JevHost], http: HTTPClient = JevClient.sharedHTTPClient, timing: Timing = Timing(),
                log: DownshiftLog? = nil, keepReplies: Bool = false) {
        self.hosts = hosts
        self.http = http
        self.timing = timing
        self.log = log
        self.keepReplies = keepReplies
    }

    public func ask(_ request: SystemOneRequest) async -> JevOutcome {
        let start = ContinuousClock.now
        func finish(_ result: SystemOneResult?, host: String?, failure: String?, attempts: [JevOutcome.Attempt]) -> JevOutcome {
            let outcome = JevOutcome(result: result, host: host, failure: failure, attempts: attempts,
                                     milliseconds: Self.milliseconds(ContinuousClock.now - start))
            log?.debug("jev \(outcome.summary)")
            return outcome
        }

        guard !hosts.isEmpty else { return finish(nil, host: nil, failure: "no-hosts", attempts: []) }
        // The types already rule out requests the schema rejects; this guards against a newer,
        // stricter schema. Such a request would only earn a 400, so it is never sent.
        let violations = JevRequestSchema.schema.validate(request.json)
        guard violations.isEmpty else {
            log?.debug("jev request failed the schema: \(violations.map(\.description).joined(separator: "; "))")
            return finish(nil, host: nil, failure: "schema-invalid", attempts: [])
        }

        let deadline = NIODeadline.now() + TimeAmount(timing.deadline)
        var attempts: [JevOutcome.Attempt] = []
        hostLoop: for host in hosts {
            let call = host.httpRequest(request)
            for attempt in 0...max(0, timing.retries) {
                if attempt > 0 {
                    let backoff = min(timing.backoffInitial * (1 << (attempt - 1)), timing.backoffMax)
                    guard NIODeadline.now() + TimeAmount(backoff) < deadline else { break hostLoop }
                    do { try await Task.sleep(for: backoff) } catch { break hostLoop }
                }
                if Task.isCancelled || NIODeadline.now() >= deadline { break hostLoop }
                let attemptDeadline = min(NIODeadline.now() + TimeAmount(timing.attemptTimeout), deadline)
                let (result, record) = await send(call, host: host, deadline: attemptDeadline)
                attempts.append(record)
                if let result { return finish(result, host: host.id, failure: nil, attempts: attempts) }
                if !record.retryable { continue hostLoop }
            }
        }
        let failure = NIODeadline.now() >= deadline ? "timeout" : (attempts.last?.reason ?? "unavailable")
        return finish(nil, host: nil, failure: failure, attempts: attempts)
    }

    func send(_ call: JevHost.HTTPRequest, host: JevHost, deadline: NIODeadline) async -> (SystemOneResult?, JevOutcome.Attempt) {
        let start = ContinuousClock.now
        var reply: JSONValue?
        func record(_ reason: String, status: Int? = nil, message: String? = nil, retryable: Bool) -> JevOutcome.Attempt {
            JevOutcome.Attempt(host: host.id, reason: reason, status: status, message: message.map { String($0.prefix(300)) },
                               retryable: retryable, milliseconds: Self.milliseconds(ContinuousClock.now - start),
                               reply: keepReplies ? reply : nil)
        }

        var outbound = HTTPClientRequest(url: call.url)
        outbound.method = .POST
        for header in call.headers { outbound.headers.add(name: header.name, value: header.value) }
        outbound.body = .bytes(ByteBuffer(bytes: call.body.serialized()))

        let status: Int
        let bytes: ByteBuffer
        do {
            let response = try await http.execute(outbound, deadline: deadline)
            status = Int(response.status.code)
            bytes = try await response.body.collect(upTo: Self.maxReply)
        } catch let error as HTTPClientError where error == .deadlineExceeded || error == .connectTimeout || error == .readTimeout {
            return (nil, record("timeout", retryable: true))
        } catch is CancellationError {
            return (nil, record("cancelled", retryable: false))
        } catch {
            return (nil, record("transport", message: "\(error)", retryable: true))
        }

        let body = try? JSONValue.parse(bytes.readableBytesView)
        reply = body
        guard (200..<300).contains(status) else {
            let retryable = status == 408 || status == 429 || status >= 500
            return (nil, record("http-\(status)", status: status, message: JevHost.errorMessage(body), retryable: retryable))
        }
        guard let body else { return (nil, record("unreadable-reply", status: status, retryable: false)) }
        do {
            let result = try SystemOneResult(json: host.normalize(body))
            return (result, record("ok", status: status, retryable: false))
        } catch let error as JevResponseError {
            return (nil, record("schema-invalid", status: status, message: error.description, retryable: false))
        } catch {
            return (nil, record("bad-reply", status: status, message: "\(error)", retryable: false))
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

/// What one `JevClient.ask` did.
public struct JevOutcome: Sendable {
    public struct Attempt: Sendable, Hashable {
        public var host: String
        /// `ok`, `timeout`, `transport`, `http-401`, `schema-invalid`, ...
        public var reason: String
        public var status: Int?
        /// The host's error text or the schema violations. It is not prompt text, but it can
        /// quote the request, so it is shown by `dshift hosts test` and never written to logs.
        public var message: String?
        public var retryable: Bool
        public var milliseconds: Int
        /// The raw reply, only when the client keeps replies.
        public var reply: JSONValue?
    }

    public var result: SystemOneResult?
    /// The host that answered.
    public var host: String?
    /// Why there is no result: `no-hosts`, `schema-invalid`, `timeout`, or the last attempt's reason.
    public var failure: String?
    public var attempts: [Attempt]
    public var milliseconds: Int

    /// One log line without any bodies or host messages.
    public var summary: String {
        let tries = attempts.map { "\($0.host):\($0.reason)(\($0.milliseconds)ms)" }.joined(separator: " ")
        let head = result != nil ? "answered by \(host ?? "?")" : "failed (\(failure ?? "unknown"))"
        return "\(head) in \(milliseconds)ms" + (tries.isEmpty ? "" : " [\(tries)]")
    }
}

extension TimeAmount {
    init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        self = .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }
}
