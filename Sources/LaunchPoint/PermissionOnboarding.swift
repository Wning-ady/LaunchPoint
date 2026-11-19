import AppKit
import SwiftUI

/// One screen keeps all three permissions and their live status visible.
struct PermissionOnboardingOverlay: View {
    let finish: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AppTheme.settingsBlue)
                            .frame(width: 48, height: 48)
                            .background(AppTheme.settingsBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("卸载权限")
                                .font(.system(size: 22, weight: .bold))
                            Text("授权状态自动更新")
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        Spacer()
                        Button(action: finish) {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityLabel("关闭权限引导")
                    }
                    ScrollView {
                        VStack(spacing: 8) {
                            PermissionAccessRow(pane: .appManagement)
                            Divider()
                            PermissionAccessRow(pane: .fullDiskAccess)
                            Divider()
                            PermissionAccessRow(pane: .automation)
                        }
                        .padding(16)
                        .background(AppTheme.settingsCard, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: 310)
                    HStack {
                        Button("稍后") { finish() }.buttonStyle(.plain)
                            .foregroundStyle(AppTheme.secondaryText)
                        Spacer()
                        Button("开始使用") { finish() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .frame(width: max(1, min(520, geometry.size.width - 32)),
                       height: max(1, min(410, geometry.size.height - 32)))
                .foregroundStyle(AppTheme.charcoal)
                .background(AppTheme.settingsCanvas, in: RoundedRectangle(cornerRadius: 22))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.25), radius: 25, y: 10)
                .environment(\.colorScheme, .light)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .livePermissionUpdates()
    }
}
