import AppKit
import CoreServices

// PermissionGuide only needs these UI hooks when opening settings or requesting access.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func dismissOverlay() {}
    func showOverlay() {}
}

@main
struct FinderPermissionStatusFixture {
    static func main() {
        let enabled = PermissionGuide.finderStatus(for: noErr)
        precondition(enabled.0 == .enabled && enabled.1 == nil)
        let denied = PermissionGuide.finderStatus(for: OSStatus(errAEEventNotPermitted))
        precondition(denied.0 == .disabled && denied.1 == nil)
        let undetermined = PermissionGuide.finderStatus(for: OSStatus(errAEEventWouldRequireUserConsent))
        precondition(undetermined.0 == .unknown && undetermined.1?.contains("尚未请求") == true)
        let failure = PermissionGuide.finderStatus(for: OSStatus(procNotFound))
        precondition(failure.0 == .unknown && failure.1?.contains("无法检查") == true)
        let suite = "LaunchPoint.PermissionConfirmationFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PermissionGuideStatus(defaults: defaults)
        precondition(first.fullDiskStatus == .unknown && first.appManagementStatus == .unknown)
        first.confirm(.fullDiskAccess, status: .enabled)
        first.confirm(.appManagement, status: .disabled)
        let reopened = PermissionGuideStatus(defaults: defaults)
        precondition(reopened.fullDiskStatus == .enabled && reopened.appManagementStatus == .disabled)
        reopened.confirm(.fullDiskAccess, status: .unknown)
        precondition(PermissionGuideStatus(defaults: defaults).fullDiskStatus == .unknown)
        reopened.confirm(.automation, status: .enabled)
        precondition(reopened.finderStatus == .unknown, "Manual records must not override system Finder status")
        print("Finder permission status checks passed")
    }
}
