import AppKit
import Foundation

/// Verifies that changing an app's localized name invalidates a cached search
/// ranking even when its path and alias stay the same.
@main
struct SearchEngineCacheFixture {
    static func main() throws {
        let url = URL(fileURLWithPath: "/tmp/LaunchPointSearchCacheFixture.app")
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let before = AppItem(id: url.path,
                             name: "Calculator",
                             url: url,
                             icon: icon,
                             bundleID: nil,
                             alias: nil)
        let after = AppItem(id: url.path + "/localized",
                            name: "Calendar",
                            url: url,
                            icon: icon,
                            bundleID: nil,
                            alias: nil)

        let first = SearchEngine.rank("calc", in: [before])
        try require(first.map(\.name) == ["Calculator"],
                    "Initial ranking failed: \(first.map(\.name))")

        let second = SearchEngine.rank("calc", in: [after])
        try require(second.isEmpty,
                    "Stale ranking survived name change: \(second.map(\.name))")

        let favoriteFirst = SearchEngine.rank(
            "cal",
            in: [before, after],
            favoriteRanks: [before.id: 0]
        )
        try require(favoriteFirst.map(\.name) == ["Calculator", "Calendar"],
                    "Favorite priority failed: \(favoriteFirst.map(\.name))")
        print("PASS search-cache-invalidates-on-name-change=true favorite-priority=true")
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
