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
        // AppActions intentionally moves the fixture bundle to the user's
        // Trash. Remove that disposable test artifact when the fixture exits,
        // so repeated regression runs do not pollute Finder's Trash.
        let trashedFixture = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
        defer { try? fm.removeItem(at: trashedFixture) }
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

        // A stale LaunchPoint entry may point at an app that was already moved
        // to Trash. Cleanup should remove its known residuals directly and must
        // not open Finder (or trigger another authorization prompt) just because
        // the app bundle itself is missing.
        try fm.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: applicationSupport.appendingPathComponent("stale"))
        var staleCompletion: String??
        var finderFallbackCalled = false
        AppActions.uninstall(
            appURL: appURL,
            bundleID: bundleID,
            beforeFinderFallback: { finderFallbackCalled = true },
            completion: { staleCompletion = $0 }
        )
        while staleCompletion == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if let error = staleCompletion! {
            throw FixtureError("Stale cleanup reported an error: \(error)")
        }
        guard !finderFallbackCalled,
              !fm.fileExists(atPath: applicationSupport.path) else {
            throw FixtureError("Stale cleanup used Finder or left residual data")
        }
        print("PASS bundle=\(bundleID) delayed-recreation-cleaned=true stale-entry-no-finder=true")
    }

    private struct FixtureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
