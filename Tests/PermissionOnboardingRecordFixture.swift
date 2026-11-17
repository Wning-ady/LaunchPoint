import Foundation

@main
struct PermissionOnboardingRecordFixture {
    static func main() {
        let name = "LaunchPoint.PermissionOnboardingFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let key = PermissionOnboardingRecord.key
        func pending(_ version: String) -> Bool {
            PermissionOnboardingRecord.shouldPresent(version: version,
                completedVersion: defaults.string(forKey: key))
        }

        precondition(pending("0.1.7"), "Fresh installs need the guide")
        // Opening or closing the overlay does not persist completion.
        precondition(pending("0.1.7"), "An interrupted guide must resume")
        PermissionOnboardingRecord.complete(version: "0.1.7", defaults: defaults)
        precondition(!pending("0.1.7"), "A completed guide should stay dismissed")
        precondition(pending("0.1.8"), "An upgrade needs the guide again")
        precondition(!pending("0.1.6"), "A downgrade is not an upgrade")
        PermissionOnboardingRecord.complete(version: "0.1.8", defaults: defaults)
        precondition(!pending("0.1.8"), "Completed upgrade should stay dismissed")
        precondition(pending("0.1.10"), "Version numbers must compare numerically")
        PermissionOnboardingRecord.complete(version: "0.1.6", defaults: defaults)
        precondition(defaults.string(forKey: key) == "0.1.8", "Downgrade cannot erase newer completion")
        print("Permission onboarding record checks passed")
    }
}
