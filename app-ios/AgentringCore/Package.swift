// swift-tools-version: 5.9
import PackageDescription

// Pure-Swift core of the iOS app: protocol models, push verification, relay REST
// client and resumable WebSocket. No third-party dependencies; builds and tests on
// Linux too (`swift test`), so the protocol logic is checked without Xcode.
let package = Package(
    name: "AgentringCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentringCore", targets: ["AgentringCore"]),
    ],
    targets: [
        .target(name: "AgentringCore"),
        .testTarget(name: "AgentringCoreTests", dependencies: ["AgentringCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
