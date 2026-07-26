// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchpadClone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LaunchpadClone",
            path: "Sources/LaunchpadClone"
        )
    ]
)
