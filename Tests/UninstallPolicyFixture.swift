import Foundation

/// Guards the password-prompt policy: ordinary /Applications apps should try
/// FileManager first, while protected system locations may use Finder first.
@main
struct UninstallPolicyFixture {
    static func main() throws {
        try require(!AppActions.shouldUseFinderFirst(for: "/Applications/Example.app"),
                    "Ordinary /Applications app incorrectly uses Finder first")
        try require(AppActions.shouldUseFinderFirst(for: "/System/Applications/Mail.app"),
                    "System application did not use Finder-first policy")
        try require(AppActions.shouldUseFinderFirst(for: "/Library/Application Support/Example.app"),
                    "Protected /Library app did not use Finder-first policy")
        try require(!AppActions.shouldUseFinderFirst(for: "/Users/test/Applications/Example.app"),
                    "User Applications path incorrectly uses Finder first")
        try require(AppActions.isUninstallableApp(
                        at: URL(fileURLWithPath: "/Applications/Example.app")),
                    "Regular app bundle was not marked uninstallable")
        try require(!AppActions.isUninstallableApp(
                        at: URL(fileURLWithPath: "/Applications/tool")),
                    "Standalone executable was marked uninstallable")
        try require(!AppActions.isUninstallableApp(
                        at: URL(fileURLWithPath: "/System/Applications/Mail.app")),
                    "System app was marked uninstallable")
        print("PASS ordinary-app-no-finder-first=true protected-system-finder-first=true standalone-protected=true")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw FixtureError(message) }
    }

    private struct FixtureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
