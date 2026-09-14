// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexAppServerSDK",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "CodexAppServerKit", targets: ["CodexAppServerKit"]),
        .library(name: "CodexAppServerHost", targets: ["CodexAppServerHost"]),
        .library(name: "CodexAppServerObservation", targets: ["CodexAppServerObservation"]),
        .library(name: "CodexAppServerRemoteExperimental", targets: ["CodexAppServerRemoteExperimental"]),
        .executable(name: "codex-app-server-cli", targets: ["CodexAppServerCLI"]),
    ],
    targets: [
        .target(name: "CodexAppServerKit"),
        .target(name: "CodexAppServerHost", dependencies: ["CodexAppServerKit"]),
        .target(name: "CodexAppServerObservation", dependencies: ["CodexAppServerKit"]),
        .target(name: "CodexAppServerRemoteExperimental", dependencies: ["CodexAppServerKit"]),
        .executableTarget(name: "CodexAppServerCLI", dependencies: ["CodexAppServerKit", "CodexAppServerHost", "CodexAppServerRemoteExperimental"]),
        // Shared fakes for the test targets. Not a product: it is deliberately not part of the
        // SDK's public surface, and it needs only CodexAppServerKit's public API.
        .target(name: "CodexAppServerTestSupport", dependencies: ["CodexAppServerKit"]),
        .testTarget(name: "CodexAppServerKitTests", dependencies: ["CodexAppServerKit", "CodexAppServerTestSupport"]),
        .testTarget(name: "CodexAppServerHostTests", dependencies: ["CodexAppServerHost", "CodexAppServerKit", "CodexAppServerTestSupport"]),
        .testTarget(name: "CodexAppServerObservationTests", dependencies: ["CodexAppServerObservation", "CodexAppServerKit", "CodexAppServerTestSupport"]),
        .testTarget(name: "CodexAppServerRemoteExperimentalTests", dependencies: ["CodexAppServerRemoteExperimental", "CodexAppServerKit", "CodexAppServerTestSupport"]),
        .testTarget(name: "CodexAppServerCLITests", dependencies: ["CodexAppServerCLI", "CodexAppServerKit"]),
    ],
    swiftLanguageModes: [.v6]
)
