import Foundation

/// Completing the tour records only that the instructions were seen; it does
/// not claim that macOS has granted either permission.
enum PermissionOnboardingRecord {
    static let key = "PermissionOnboardingCompletedVersion"

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "LaunchPointReleaseVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "development"
    }

    static func shouldPresent(version: String, completedVersion: String?) -> Bool {
        guard let completedVersion, !completedVersion.isEmpty else { return true }
        return version.compare(completedVersion, options: .numeric) == .orderedDescending
    }

    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        shouldPresent(version: currentVersion, completedVersion: defaults.string(forKey: key))
    }

    static func complete(version: String = currentVersion, defaults: UserDefaults = .standard) {
        let existing = defaults.string(forKey: key)
        if existing == nil || shouldPresent(version: version, completedVersion: existing) {
            defaults.set(version, forKey: key)
        }
    }
}
