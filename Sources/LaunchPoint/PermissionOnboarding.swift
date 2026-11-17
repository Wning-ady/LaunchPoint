import AppKit
import SwiftUI

/// The overlay survives hiding the window while users visit System Settings.
/// The record is saved only when the user finishes the guide explicitly.
struct PermissionOnboardingOverlay: View {
    let finish: () -> Void
    @State private var step = 0
    @State private var requestingFinder = false
    @State private var finderMessage: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(AppTheme.settingsBlue)
                                .frame(width: 52, height: 52)
                                .background(AppTheme.settingsBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("卸载权限引导")
                                    .font(.system(size: 22, weight: .bold))
                                Text("\(step + 1) / 3 · 可随时在设置中再次查看")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer(minLength: 0)
                        }

                        guideStep

                        Text("打开系统设置后，请通过 LaunchPoint 菜单栏图标或快捷键返回，继续查看引导。授权可稍后在设置中完成。")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                        HStack {
                            if step > 0 {
                                Button("上一步") { step -= 1 }
                                    .buttonStyle(.bordered)
                            }
                            Spacer()
                            if step < 2 {
                                Button("下一步") { step += 1 }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("完成引导") { finish() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .foregroundStyle(AppTheme.charcoal)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .frame(width: max(1, min(520, geometry.size.width - 32)),
                       height: max(1, min(510, geometry.size.height - 32)))
                .background(AppTheme.settingsCanvas, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 25, y: 10)
                .environment(\.colorScheme, .light)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder private var guideStep: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 10) {
                Text("应用程序管理（可选）")
                    .font(.system(size: 17, weight: .semibold))
                Text("允许 LaunchPoint 管理受保护的应用可能减少系统提示；macOS 仍可能要求输入密码。")
                Text("在系统设置的“隐私与安全性 → 应用程序管理”中，找到并打开 LaunchPoint。系统可能在首次需要时才显示此选项。")
                    .foregroundStyle(AppTheme.secondaryText)
                Button("打开应用程序管理") {
                    PermissionGuide.openSettings(.appManagement)
                }
                .buttonStyle(.bordered)
            }
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                Text("完全磁盘访问权限（可选）")
                    .font(.system(size: 17, weight: .semibold))
                Text("开启后，LaunchPoint 可以尝试访问受保护的应用容器和关联文件，帮助清理残留。部分文件仍可能无法删除。")
                Text("此权限范围较广，也可访问邮件、信息等受保护的数据。请在了解权限范围后自行决定是否开启。")
                    .foregroundStyle(AppTheme.secondaryText)
                Text("在“隐私与安全性 → 完全磁盘访问权限”中打开 LaunchPoint；若列表中没有，请使用 + 添加。")
                    .foregroundStyle(AppTheme.secondaryText)
                Button("打开完全磁盘访问权限") {
                    PermissionGuide.openSettings(.fullDiskAccess)
                }
                .buttonStyle(.bordered)
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                Text("允许控制 Finder")
                    .font(.system(size: 17, weight: .semibold))
                Text("需要 Finder 协助移到废纸篓时，LaunchPoint 可能需要获得控制 Finder 的权限。")
                Text("点击下方按钮；如果出现系统提示，请选择“好”。如果之前拒绝，请在“隐私与安全性 → 自动化”中允许 LaunchPoint 控制 Finder。")
                    .foregroundStyle(AppTheme.secondaryText)
                VStack(alignment: .leading, spacing: 8) {
                    Button(requestingFinder ? "正在请求…" : "请求 Finder 授权") {
                        requestingFinder = true
                        PermissionGuide.requestFinderAccess { allowed in
                            requestingFinder = false
                            finderMessage = allowed
                                ? "Finder 测试请求成功；卸载时如有系统提示，请继续按提示操作。"
                                : "测试未成功，请检查自动化设置或稍后重试。"
                        }
                    }
                    .disabled(requestingFinder)
                    Button("打开自动化设置") {
                        PermissionGuide.openSettings(.automation)
                    }
                }
                .buttonStyle(.bordered)
                if let finderMessage {
                    Text(finderMessage).font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
    }
}
