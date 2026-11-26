// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DedotatedWam",
    platforms: [.macOS(.v14)],
    targets: [
        // Sampling, settings, the app catalog and the triage logic. No UI, so it can be tested.
        .target(name: "WamCore", path: "Sources/WamCore"),
        // The menu bar app itself.
        .executableTarget(name: "DedotatedWam", dependencies: ["WamCore"], path: "Sources/DedotatedWam"),
        .testTarget(name: "WamCoreTests", dependencies: ["WamCore"], path: "Tests/WamCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
