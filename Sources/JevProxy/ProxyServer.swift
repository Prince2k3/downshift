import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import ServiceLifecycle
import UnixSignals

/// The loopback proxy `jev serve`, `jev claude` and `jev codex` run: Claude traffic at the
/// root, Codex traffic under `/codex`, one port, HTTP and WebSocket. Runs until SIGTERM or SIGINT, then drains
/// in-flight streams and shuts the upstream client down.
public enum ProxyServer {
    public static let claudeUpstream = "https://api.anthropic.com"
    public static let codexUpstream = "https://chatgpt.com/backend-api/codex"
    public static let codexPrefix = "/codex"

    public struct Configuration: Sendable {
        public var port: Int
        public var upstream: String
        /// Empty disables the `/codex` route.
        public var codexUpstream: String
        public var dumpDirectory: String?
        /// Routes Claude requests that ask for the sentinel model; nil passes them through.
        public var claudeEngine: RoutingEngine?
        /// Routes Codex requests that ask for the sentinel model; nil passes them through.
        public var codexEngine: RoutingEngine?
        /// How long in-flight streams may keep running after a shutdown signal before they
        /// are cancelled (plan §5b).
        public var shutdownGrace: Duration

        public init(port: Int, upstream: String = ProxyServer.claudeUpstream,
                    codexUpstream: String = ProxyServer.codexUpstream, dumpDirectory: String? = nil,
                    claudeEngine: RoutingEngine? = nil, codexEngine: RoutingEngine? = nil, shutdownGrace: Duration = .seconds(10)) {
            self.port = port
            self.upstream = upstream
            self.codexUpstream = codexUpstream
            self.dumpDirectory = dumpDirectory
            self.claudeEngine = claudeEngine
            self.codexEngine = codexEngine
            self.shutdownGrace = shutdownGrace
        }

        public var routes: [PassthroughResponder.Route] {
            var routes = [PassthroughResponder.Route(prefix: "", upstream: upstream,
                                                     interceptor: claudeEngine.map(ClaudeInterceptor.init))]
            if !codexUpstream.isEmpty { 
                routes.append(.init(prefix: ProxyServer.codexPrefix, upstream: codexUpstream,
                                    interceptor: codexEngine.map { CodexInterceptor(engine: $0) }))
            }
            return routes
        }
    }

    /// `onListening` gets the bound port (useful when `port` is 0). `cleanup` runs after the
    /// proxy has drained, e.g. to restore settings once the last stream has finished.
    /// `child` is the launchers' agent CLI: its end shuts the group down gracefully. The
    /// launchers pass no `signals`, because the child service forwards them instead.
    public static func run(_ configuration: Configuration, logger: Logger, cleanup: (any Service)? = nil,
                           child: (any Service)? = nil, signals: [UnixSignal] = [.sigterm, .sigint],
                           onListening: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        let dumper = try configuration.dumpDirectory.map { try FixtureDumper(directory: $0) }
        let client = HTTPClient.jevUpstream()
        let app = makeApplication(configuration, client: client, dumper: dumper, logger: logger, onListening: onListening)
        let group = serviceGroup(proxy: app, cleanup: cleanup, child: child, grace: configuration.shutdownGrace,
                                 signals: signals, logger: logger)
        do {
            try await group.run()
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }

    /// The group every mode runs. Services shut down in reverse order, so `cleanup` is listed
    /// first: it is only asked to stop after the proxy has stopped accepting connections and
    /// its in-flight streams have finished. Anything still running after `grace` is cancelled.
    public static func serviceGroup(proxy: any Service, cleanup: (any Service)?, child: (any Service)? = nil,
                                    grace: Duration, signals: [UnixSignal], logger: Logger) -> ServiceGroup {
        var services: [ServiceGroupConfiguration.ServiceConfiguration] = []
        if let cleanup { services.append(.init(service: cleanup)) }
        services.append(.init(service: proxy))
        if let child {
            services.append(.init(service: child, successTerminationBehavior: .gracefullyShutdownGroup,
                                  failureTerminationBehavior: .gracefullyShutdownGroup))
        }
        var configuration = ServiceGroupConfiguration(services: services, gracefulShutdownSignals: signals, logger: logger)
        configuration.maximumGracefulShutdownDuration = grace
        return ServiceGroup(configuration: configuration)
    }

    /// The HTTP + WebSocket application `run` serves, without the service group around it.
    public static func makeApplication(_ configuration: Configuration, client: HTTPClient, dumper: FixtureDumper?,
                                       logger: Logger, onListening: @escaping @Sendable (Int) -> Void = { _ in })
        -> some ApplicationProtocol {
        let webSocket = WebSocketPassthrough(routes: configuration.routes, logger: logger)
        // Frames up to the request-body limit; keepalive pings to the client every 30 s (the default).
        let upgrade = HTTP1WebSocketUpgradeChannel.Configuration(ws: .init(maxFrameSize: WebSocketPassthrough.maxMessage))
        return Application(
            responder: PassthroughResponder(client: client, routes: configuration.routes, dumper: dumper, logger: logger),
            server: .http1WebSocketUpgrade(configuration: upgrade) { head, _, _ in await webSocket.shouldUpgrade(head) },
            configuration: .init(address: .hostname("127.0.0.1", port: configuration.port), serverName: "jev"),
            onServerRunning: { channel in onListening(channel.localAddress?.port ?? 0) },
            logger: logger
        )
    }
}
