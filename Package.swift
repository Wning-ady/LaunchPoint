// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchPoint",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LaunchPoint",
            path: "Sources/LaunchPoint"
        )
    ]
)
