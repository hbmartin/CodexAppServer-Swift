// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexAppServerSDK",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "CodexAppServerKit", targets: ["CodexAppServerKit"]),
        .library(name: "CodexAppServerHost", targets: ["CodexAppServerHost"]),
        .library(name: "CodexAppServerObservation", targets: ["CodexAppServerObservation"]),
        .library(name: "CodexAppServerRemote", targets: ["CodexAppServerRemote"]),
        .executable(name: "codex-app-server-cli", targets: ["CodexAppServerCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(name: "CodexAppServerKit", dependencies: [
            .product(name: "DequeModule", package: "swift-collections"),
        ]),
        .target(name: "CodexAppServerHost", dependencies: ["CodexAppServerKit"]),
        .target(name: "CodexAppServerObservation", dependencies: ["CodexAppServerKit"]),
        .target(name: "CodexAppServerRemote", dependencies: [
            "CodexAppServerKit",
            .product(name: "DequeModule", package: "swift-collections"),
        ]),
        .executableTarget(name: "CodexAppServerCLI", dependencies: [
            "CodexAppServerKit", "CodexAppServerHost", "CodexAppServerRemote",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        // Shared fakes for the test targets. Not a product: it is deliberately not part of the
        // SDK's public surface, and it needs only CodexAppServerKit's public API.
        .target(name: "CodexAppServerTestSupport", dependencies: ["CodexAppServerKit"]),
        .testTarget(name: "CodexAppServerKitTests", dependencies: ["CodexAppServerKit", "CodexAppServerTestSupport"]),
        .testTarget(name: "CodexAppServerHostTests", dependencies: ["CodexAppServerHost", "CodexAppServerKit"]),
        .testTarget(name: "CodexAppServerObservationTests", dependencies: ["CodexAppServerObservation", "CodexAppServerKit", "CodexAppServerTestSupport"]),
        .testTarget(name: "CodexAppServerRemoteTests", dependencies: ["CodexAppServerRemote", "CodexAppServerKit", "CodexAppServerTestSupport"]),
        .testTarget(name: "CodexAppServerCLITests", dependencies: [
            "CodexAppServerCLI", "CodexAppServerKit", "CodexAppServerRemote",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
