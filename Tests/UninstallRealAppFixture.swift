import Foundation

/// Runs the current uninstall implementation against a disposable copied app
/// bundle. Set LAUNCHPOINT_REAL_APP_FIXTURE to override the test path.
@main
struct UninstallRealAppFixture {
    static func main() throws {
        let path = ProcessInfo.processInfo.environment["LAUNCHPOINT_REAL_APP_FIXTURE"]
            ?? "/tmp/LaunchPointUITest.app"
        let appURL = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: appURL.path) else {
            throw FixtureError("Temporary app is missing: \(appURL.path)")
        }
        let bundleID = Bundle(url: appURL)?.bundleIdentifier

        var completionResult: String??
        var finderFallbackCalled = false
        AppActions.uninstall(
            appURL: appURL,
            bundleID: bundleID,
            beforeFinderFallback: { finderFallbackCalled = true },
            completion: { completionResult = $0 }
        )
        while completionResult == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if let error = completionResult! {
            throw FixtureError(error)
        }
        guard !fm.fileExists(atPath: appURL.path) else {
            throw FixtureError("App still exists after uninstall: \(appURL.path)")
        }
        guard !finderFallbackCalled else {
            throw FixtureError("Ordinary temporary app unexpectedly used Finder fallback")
        }
        print("PASS real-app-trashed=true finder-fallback=\(finderFallbackCalled)")
    }

    private struct FixtureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
