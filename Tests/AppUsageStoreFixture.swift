import Foundation

/// Verifies deterministic recency and frequency ranking without touching the
/// user's standard preference domain.
@main
struct AppUsageStoreFixture {
    static func main() throws {
        let suiteName = "LaunchPointAppUsageFixture-\(UUID().uuidString)"
        let defaults = try requireDefaults(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppUsageStore(defaults: defaults)
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        store.record(appID: "older", now: epoch)
        store.record(appID: "newer", now: epoch.addingTimeInterval(3600))

        let atNewer = store.scores(for: ["older", "newer"],
                                   now: epoch.addingTimeInterval(3600))
        try require((atNewer["newer"] ?? 0) > (atNewer["older"] ?? 0),
                    "Recency score did not prefer the newer app: \(atNewer)")

        store.record(appID: "older", now: epoch.addingTimeInterval(3600))
        let afterRepeat = store.scores(for: ["older", "newer"],
                                       now: epoch.addingTimeInterval(3600))
        try require((afterRepeat["older"] ?? 0) > (afterRepeat["newer"] ?? 0),
                    "Frequency score did not prefer the repeated app: \(afterRepeat)")
        print("PASS usage-recency=true usage-frequency=true")
    }

    private static func requireDefaults(_ suiteName: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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
