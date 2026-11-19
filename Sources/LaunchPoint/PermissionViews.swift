import AppKit
import SwiftUI
import Combine

/// The guide and settings share the same live state and presentation.
struct PermissionStatusBadge: View {
    let pane: PermissionGuide.PrivacyPane
    @ObservedObject private var permissions = PermissionGuideStatus.shared

    private var status: PermissionAccessStatus {
        switch pane {
        case .fullDiskAccess: return permissions.fullDiskStatus
        case .appManagement: return permissions.appManagementStatus
        case .automation: return permissions.finderStatus
        }
    }

    var body: some View {
        Group {
            if !permissions.hasChecked {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("检测中")
                }
                .foregroundStyle(.secondary)
            } else {
                Label(title, systemImage: status == .enabled ? "checkmark.circle.fill"
                      : status == .disabled ? "exclamationmark.circle.fill" : "questionmark.circle")
                    .foregroundStyle(status == .enabled ? Color.green
                                     : status == .disabled ? Color.orange : Color.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .fixedSize()
        .accessibilityLabel("\(pane.name)：\(title)")
    }

    private var title: String {
        switch status {
        case .enabled:
            return pane == .appManagement && permissions.appManagementUsesProbe ? "可管理" : "已开启"
        case .disabled:
            // A failed access probe cannot establish that a Settings switch is
            // off. In particular, a re-signed update can invalidate an old grant.
            return pane == .fullDiskAccess ? "未生效" : pane == .appManagement ? "受限制" : "未开启"
        case .unknown: return "待确认"
        }
    }
}

struct PermissionAccessRow: View {
    let pane: PermissionGuide.PrivacyPane
    @ObservedObject private var permissions = PermissionGuideStatus.shared
    @State private var requesting = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(AppTheme.settingsBlue)
                .frame(width: 40, height: 40)
                .background(AppTheme.settingsBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(pane == .automation ? "Finder 自动化" : pane.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                PermissionStatusBadge(pane: pane)
                HStack(spacing: 4) {
                    Button(actionTitle, action: primaryAction)
                        .disabled(requesting)
                    Menu {
                        Button("系统设置") { PermissionGuide.openSettings(pane) }
                        Button("兼容入口") { PermissionGuide.openSettings(pane, compatibility: true) }
                        Divider()
                        Button("重新检测") { PermissionGuide.refreshPermissionStatuses() }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("\(pane.name)更多操作")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .foregroundStyle(AppTheme.charcoal)
    }

    private var symbol: String {
        switch pane {
        case .fullDiskAccess: return "externaldrive"
        case .appManagement: return "app.badge"
        case .automation: return "folder.badge.gearshape"
        }
    }

    private var subtitle: String {
        switch pane {
        case .fullDiskAccess: return "清理受保护数据 · 可选"
        case .appManagement: return "移除应用"
        case .automation: return "通过 Finder 移到废纸篓"
        }
    }

    private var actionTitle: String {
        if requesting { return "等待授权…" }
        if pane == .automation && permissions.finderStatus != .enabled { return "授权" }
        if pane == .fullDiskAccess && permissions.fullDiskStatus == .disabled { return "重新授权" }
        return "设置"
    }

    private func primaryAction() {
        if pane == .automation && permissions.finderStatus != .enabled {
            requesting = true
            PermissionGuide.requestFinderAccess { _ in
                requesting = false
                PermissionGuide.refreshPermissionStatuses()
            }
        } else {
            PermissionGuide.openSettings(pane)
        }
    }
}

private struct LivePermissionUpdates: ViewModifier {
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .onAppear { PermissionGuide.refreshPermissionStatuses() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                PermissionGuide.refreshPermissionStatuses()
            }
            .onReceive(timer) { _ in
                if NSApp.isActive { PermissionGuide.refreshPermissionStatuses() }
            }
    }
}

extension View {
    func livePermissionUpdates() -> some View { modifier(LivePermissionUpdates()) }
}
