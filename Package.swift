// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchPoint",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LaunchPoint",
            path: "Sources/LaunchPoint",
            // The app predates Swift 6's strict concurrency checking and
            // intentionally centralizes UI state on AppKit's main thread.
            // Keep SwiftPM builds aligned with the direct swiftc build script
            // until the whole UI state graph can be actor-isolated together.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
