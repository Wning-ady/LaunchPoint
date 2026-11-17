import AppKit
import Foundation
import CoreServices

enum PermissionAccessStatus {
    case enabled
    case disabled
    case unknown
}

final class PermissionGuideStatus: ObservableObject {
    static let shared = PermissionGuideStatus()
    @Published var finderMessage: String?
    @Published var fullDiskStatus: PermissionAccessStatus = .unknown
    @Published var appManagementStatus: PermissionAccessStatus = .unknown
    @Published var finderStatus: PermissionAccessStatus = .unknown
    @Published var finderStatusDetail: String?
}

/// System privacy controls live outside LaunchPoint. Hide its floating overlay
/// before opening them so it cannot cover System Settings or the system prompt.
enum PermissionGuide {
    private static let finderScriptQueue = DispatchQueue(label: "com.waning.launchpoint.finder-permission")

    /// Check without sending an event or asking the user. Apple requires a
    /// running target and recommends doing this off the main thread.
    static func refreshFinderStatus() {
        finderScriptQueue.async {
            let (status, detail) = finderStatus(for: determineFinderPermission(askUserIfNeeded: false))
            DispatchQueue.main.async {
                PermissionGuideStatus.shared.finderStatus = status
                PermissionGuideStatus.shared.finderStatusDetail = detail
                // A previous request result can become stale after the user
                // changes the switch in System Settings.
                PermissionGuideStatus.shared.finderMessage = nil
            }
        }
    }

    static func refreshPermissionStatuses() {
        refreshFinderStatus()
    }

    /// The API requires a running target and must run on the serial queue.
    private static func determineFinderPermission(askUserIfNeeded: Bool) -> OSStatus {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return OSStatus(procNotFound)
        }
        let descriptor = NSAppleEventDescriptor(processIdentifier: finder.processIdentifier)
        return withExtendedLifetime(descriptor) {
            guard let address = descriptor.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUserIfNeeded)
        }
    }

    static func finderStatus(for result: OSStatus) -> (PermissionAccessStatus, String?) {
        switch result {
        case noErr:
            return (.enabled, nil)
        case OSStatus(errAEEventNotPermitted):
            return (.disabled, nil)
        case OSStatus(errAEEventWouldRequireUserConsent):
            return (.unknown, "尚未请求 Finder 自动化授权。")
        default:
            return (.unknown, "暂时无法检查 Finder 自动化权限，请稍后重试。")
        }
    }

    enum PrivacyPane {
        case fullDiskAccess
        case appManagement
        case automation

        var url: URL {
            let anchor: String
            switch self {
            case .fullDiskAccess: anchor = "Privacy_AllFiles"
            case .appManagement: anchor = "Privacy_AppBundles"
            case .automation: anchor = "Privacy_Automation"
            }
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")!
        }

        var name: String {
            switch self {
            case .fullDiskAccess: return "完全磁盘访问权限"
            case .appManagement: return "应用程序管理"
            case .automation: return "自动化"
            }
        }
    }

    static func openSettings(_ pane: PrivacyPane) {
        (NSApp.delegate as? AppDelegate)?.dismissOverlay()
        // Wait for the overlay's closing animation and deactivation to finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !NSWorkspace.shared.open(pane.url) else { return }
            (NSApp.delegate as? AppDelegate)?.showOverlay()
            let alert = NSAlert()
            alert.messageText = "无法打开系统设置"
            alert.informativeText = "请手动打开系统设置 → 隐私与安全性 → \(pane.name)。如果 LaunchPoint 暂未出现在列表中，请在需要时操作或按系统提示授权。"
            alert.addButton(withTitle: "好")
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    /// Ask for permission to send all Finder events. Previously denied access
    /// is managed in System Settings; macOS does not repeat the original prompt.
    static func requestFinderAccess(completion: @escaping (Bool) -> Void) {
        (NSApp.delegate as? AppDelegate)?.dismissOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            finderScriptQueue.async {
                let result = determineFinderPermission(askUserIfNeeded: true)
                let (status, detail) = finderStatus(for: result)
                DispatchQueue.main.async {
                    PermissionGuideStatus.shared.finderStatus = status
                    PermissionGuideStatus.shared.finderStatusDetail = detail
                    PermissionGuideStatus.shared.finderMessage = nil
                    completion(result == noErr)
                }
            }
        }
    }
}
