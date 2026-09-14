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
        .testTarget(name: "CodexAppServerKitTests", dependencies: ["CodexAppServerKit"]),
        .testTarget(name: "CodexAppServerHostTests", dependencies: ["CodexAppServerHost", "CodexAppServerKit"]),
        .testTarget(name: "CodexAppServerObservationTests", dependencies: ["CodexAppServerObservation", "CodexAppServerKit"]),
        .testTarget(name: "CodexAppServerRemoteExperimentalTests", dependencies: ["CodexAppServerRemoteExperimental", "CodexAppServerKit"]),
        .testTarget(name: "CodexAppServerCLITests", dependencies: ["CodexAppServerCLI", "CodexAppServerKit"]),
    ],
    swiftLanguageModes: [.v6]
)
