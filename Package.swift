// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "downshift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dshift", targets: ["dshift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "dshift",
            dependencies: [
                "DownshiftCore", "JevHosts", "DownshiftProxy", "DownshiftAgents", "DownshiftLaunch",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(name: "DownshiftCore"),
        .target(
            name: "JevHosts",
            dependencies: [
                "DownshiftCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "DownshiftProxy",
            dependencies: [
                "DownshiftCore", "JevHosts",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "DownshiftAgents",
            dependencies: [
                "DownshiftCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "DownshiftLaunch",
            dependencies: [
                "DownshiftCore", "JevHosts", "DownshiftProxy", "DownshiftAgents",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "DownshiftCoreTests", dependencies: ["DownshiftCore"]),
        .testTarget(
            name: "DownshiftLaunchTests",
            dependencies: [
                "DownshiftLaunch", "DownshiftCore", "DownshiftProxy", "DownshiftAgents",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "DownshiftAgentsTests", dependencies: ["DownshiftAgents", "DownshiftCore"]),
        .testTarget(
            name: "JevHostsTests",
            dependencies: [
                "JevHosts", "DownshiftCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        .testTarget(
            name: "DownshiftProxyTests",
            dependencies: [
                "DownshiftProxy", "DownshiftCore", "JevHosts",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
            ]
        ),
    ]
)
