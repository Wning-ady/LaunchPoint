import AppKit
import Foundation

/// Standalone integration fixture. Compile it together with AppActions.swift:
/// xcrun swiftc Sources/LaunchPoint/AppActions.swift Tests/UninstallIntegrationFixture.swift \
///   -framework AppKit -framework Security -o /tmp/LaunchPointUninstallFixture
@main
struct UninstallIntegrationFixture {
    static func main() throws {
        let fm = FileManager.default
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let bundleID = "com.waning.LaunchPointUninstallFixture.\(suffix)"
        let appURL = fm.temporaryDirectory
            .appendingPathComponent("LaunchPointUninstallFixture-\(suffix).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fm.createDirectory(at: executableDirectory, withIntermediateDirectories: true)

        let plist: NSDictionary = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "LaunchPointUninstallFixture-\(suffix)",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
        ]
        guard plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true) else {
            throw FixtureError("Unable to write fixture Info.plist")
        }
        let executable = executableDirectory.appendingPathComponent("Fixture")
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)

        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let applicationSupport = library.appendingPathComponent(
            "Application Support/\(bundleID)", isDirectory: true
        )
        let preference = library.appendingPathComponent("Preferences/\(bundleID).plist")
        try fm.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        guard NSDictionary(dictionary: ["fixture": true]).write(to: preference, atomically: true) else {
            throw FixtureError("Unable to write fixture preference")
        }

        // Recreate one item after the first cleanup pass. This models a
        // sandbox process/containermanagerd writing data during termination.
        let recreator = Process()
        recreator.executableURL = URL(fileURLWithPath: "/bin/sh")
        recreator.arguments = [
            "-c",
            "sleep 0.6; mkdir -p \"$1\"; touch \"$1/recreated-after-first-pass\"",
            "fixture-recreator",
            applicationSupport.path,
        ]
        try recreator.run()

        var completionResult: String??
        AppActions.uninstall(
            appURL: appURL,
            bundleID: bundleID,
            beforeFinderFallback: {},
            completion: { completionResult = $0 }
        )
        while completionResult == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        recreator.waitUntilExit()

        if let error = completionResult! {
            throw FixtureError("Uninstall reported an error: \(error)")
        }
        let leftovers = [appURL, applicationSupport, preference].filter {
            fm.fileExists(atPath: $0.path)
        }
        guard leftovers.isEmpty else {
            throw FixtureError("Leftovers remain: \(leftovers.map(\.path).joined(separator: ", "))")
        }
        print("PASS bundle=\(bundleID) delayed-recreation-cleaned=true")
    }

    private struct FixtureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
