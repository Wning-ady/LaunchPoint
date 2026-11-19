import AppKit
import Foundation
import CoreServices
import Darwin
import Security
import SQLite3

enum PermissionAccessStatus: String {
    case enabled
    case disabled
    case unknown
}

final class PermissionGuideStatus: ObservableObject {
    static let shared = PermissionGuideStatus()
    @Published var hasChecked = false
    @Published var isRefreshing = false
    @Published var finderMessage: String?
    @Published var fullDiskStatus: PermissionAccessStatus = .unknown
    @Published var appManagementStatus: PermissionAccessStatus = .unknown
    @Published var appManagementUsesProbe = false
    @Published var appManagementDetail: String?
    @Published var finderStatus: PermissionAccessStatus = .unknown
    @Published var finderStatusDetail: String?

    /// Saved user confirmations never establish an effective permission.
    init(defaults: UserDefaults = .standard) {}
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
        // Polling and app activation can coincide; never queue overlapping probes
        // or leave the UI showing values from different refresh generations.
        let state = PermissionGuideStatus.shared
        guard !state.isRefreshing else { return }
        state.isRefreshing = true
        finderScriptQueue.async {
            let disk = fullDiskStatus()
            let management = appManagementStatus()
            let probe = management == .unknown ? probeAppManagement() : nil
            let finder = finderStatus(for: determineFinderPermission(askUserIfNeeded: false))
            DispatchQueue.main.async {
                state.fullDiskStatus = disk
                state.appManagementStatus = probe?.0 ?? management
                state.appManagementUsesProbe = probe != nil
                state.appManagementDetail = probe?.1
                state.finderStatus = finder.0
                state.finderStatusDetail = finder.1
                state.finderMessage = nil
                state.hasChecked = true
                state.isRefreshing = false
            }
        }
    }

    /// Probe a system TCC-protected file without reading its contents. A missing
    /// file or a Unix permission error cannot establish the privacy switch.
    static func fullDiskStatus() -> PermissionAccessStatus {
        let descriptor = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC)
        if descriptor >= 0 {
            close(descriptor)
            return .enabled
        }
        return fullDiskStatus(openError: errno)
    }

    static func fullDiskStatus(openError: Int32) -> PermissionAccessStatus {
        openError == EPERM ? .disabled : .unknown
    }

    /// Best-effort read of this app's TCC record, never a private TCC API or a
    /// database write. Schema/access changes fall back to unknown. A matching
    /// bundle ID alone is insufficient after an app has been replaced/re-signed.
    static func appManagementStatus() -> PermissionAccessStatus {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let executable = Bundle.main.executableURL else { return .unknown }
        let databases = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        ]
        let identities: [(String, Int32)] = [(bundleID, 0), (Bundle.main.bundleURL.path, 1), (executable.path, 1)]
        let statuses = databases.flatMap { database in
            identities.compactMap { client, type in
                appManagementRecord(databaseURL: database, client: client, clientType: type,
                                    codeURL: Bundle.main.bundleURL)
            }
        }
        guard let first = statuses.first, statuses.allSatisfy({ $0 == first }) else { return .unknown }
        return first
    }

    static func appManagementRecord(databaseURL: URL, client: String, clientType: Int32,
                                    codeURL: URL) -> PermissionAccessStatus? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        let query = "SELECT auth_value, csreq FROM access WHERE service = 'kTCCServiceSystemPolicyAppBundles' AND client = ? AND client_type = ?"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, client, -1, transient) == SQLITE_OK,
              sqlite3_bind_int(statement, 2, clientType) == SQLITE_OK else { return nil }
        var statuses: [PermissionAccessStatus] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  let bytes = sqlite3_column_blob(statement, 1) else { return .unknown }
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard count > 0 else { return .unknown }
            let data = Data(bytes: bytes, count: count)
            var requirement: SecRequirement?
            var code: SecStaticCode?
            guard SecRequirementCreateWithData(data as CFData, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecStaticCodeCreateWithPath(codeURL as CFURL, [], &code) == errSecSuccess,
                  let code,
                  SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return .unknown }
            switch sqlite3_column_int(statement, 0) {
            case 0: statuses.append(.disabled)
            case 2: statuses.append(.enabled)
            default: return .unknown
            }
        }
        guard let first = statuses.first else { return nil }
        return statuses.allSatisfy { $0 == first } ? first : .unknown
    }

    /// macOS 27 protects the per-user TCC database even when Full Disk Access
    /// is granted. Report an observed capability instead of inventing a switch
    /// value. Opening O_WRONLY without O_TRUNC/O_CREAT does not change the file;
    /// macOS may request App Management consent when it checks this operation.
    static func probeAppManagement() -> (PermissionAccessStatus, String?) {
        let ownURL = Bundle.main.bundleURL.standardizedFileURL
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var deniedApp: String?
        var attempts = 0
        for root in roots {
            let apps = (try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
            for app in apps.sorted(by: { $0.path < $1.path }) {
                guard app.pathExtension == "app", app.standardizedFileURL != ownURL,
                      (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                      let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier,
                      !identifier.hasPrefix("com.apple."), identifier != Bundle.main.bundleIdentifier else { continue }
                let file = app.appendingPathComponent("Contents/Info.plist")
                // Skip Unix ownership/ACL and system volume limitations rather
                // than misreporting those as a privacy denial.
                guard isOwnedWritableRegularFile(file) else { continue }
                attempts += 1
                let status = probeWriteAccess(at: file)
                if status == .enabled {
                    return (.enabled, "已验证“\(app.deletingPathExtension().lastPathComponent)”的文件写入访问，未修改任何内容。这是实际访问结果，不是系统开关查询；其他应用或残留文件仍可能有额外限制。")
                }
                if status == .disabled { deniedApp = app.deletingPathExtension().lastPathComponent }
                if attempts >= 8 { break }
            }
            if attempts >= 8 { break }
        }
        if let deniedApp {
            return (.disabled, "系统阻止了对“\(deniedApp)”的写入访问。请在系统设置确认 App 管理授权；文件自身的保护也可能造成拒绝。")
        }
        return (.unknown, "无法读取系统授权记录，也未找到可验证的应用文件。请到系统设置查看 App 管理开关。")
    }

    private static func isOwnedWritableRegularFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid()
            && (info.st_mode & S_IWUSR) != 0
    }

    static func probeWriteAccess(at url: URL) -> PermissionAccessStatus {
        guard isOwnedWritableRegularFile(url) else { return .unknown }
        // Reject symlinks even if a path is replaced between lstat and open.
        let descriptor = open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return writeAccessStatus(openError: errno) }
        close(descriptor)
        return .enabled
    }

    static func writeAccessStatus(openError: Int32) -> PermissionAccessStatus {
        openError == EPERM ? .disabled : .unknown
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

    enum PrivacyPane: String {
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

        var compatibilityURL: URL {
            URL(string: url.absoluteString.replacingOccurrences(
                of: "com.apple.settings.PrivacySecurity.extension",
                with: "com.apple.preference.security"
            ))!
        }
    }

    static func openSettings(_ pane: PrivacyPane, compatibility: Bool = false) {
        (NSApp.delegate as? AppDelegate)?.dismissOverlay()
        // Route only after System Settings has launched. Delivering a deep link
        // during a cold launch can leave the app on its restored/default page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
                showSettingsError(pane)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard error == nil else { showSettingsError(pane); return }
                    let destination = compatibility ? pane.compatibilityURL : pane.url
                    guard NSWorkspace.shared.open(destination) else { showSettingsError(pane); return }
                }
            }
        }
    }

    private static func showSettingsError(_ pane: PrivacyPane) {
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
