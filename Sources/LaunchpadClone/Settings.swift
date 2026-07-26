import SwiftUI
import Carbon.HIToolbox

/// 唤起快捷键选项(v1 提供常用组合;完全自定义录制后续做)。
enum HotkeyOption: String, CaseIterable, Identifiable {
    case optionSpace
    case controlSpace
    case optionCommandSpace
    case controlOptionSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: return "⌥ 空格"
        case .controlSpace: return "⌃ 空格"
        case .optionCommandSpace: return "⌥⌘ 空格"
        case .controlOptionSpace: return "⌃⌥ 空格"
        }
    }

    var keyCode: UInt32 { UInt32(kVK_Space) }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlSpace: return UInt32(controlKey)
        case .optionCommandSpace: return UInt32(optionKey | cmdKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        }
    }
}

/// 用户设置(UserDefaults 持久化,参照 LaunchOS 的 columns/rows/快捷键键值设计)。
enum Settings {
    private static let defaults = UserDefaults.standard

    static var columns: Int {
        get {
            let value = defaults.integer(forKey: "GridColumns")
            return value == 0 ? 7 : min(max(value, 5), 10)
        }
        set { defaults.set(min(max(newValue, 5), 10), forKey: "GridColumns") }
    }

    static var rows: Int {
        get {
            let value = defaults.integer(forKey: "GridRows")
            return value == 0 ? 5 : min(max(value, 3), 8)
        }
        set { defaults.set(min(max(newValue, 3), 8), forKey: "GridRows") }
    }

    static var hotkeyOption: HotkeyOption {
        get {
            HotkeyOption(rawValue: defaults.string(forKey: "HotkeyOption") ?? "") ?? .optionSpace
        }
        set { defaults.set(newValue.rawValue, forKey: "HotkeyOption") }
    }
}

/// 设置面板(⌘, 打开;修改即时生效)。
struct SettingsPanel: View {
    @Environment(\.dismiss) private var dismissSheet
    @State private var hotkey = Settings.hotkeyOption
    @State private var columns = LayoutStore.columns
    @State private var rows = LayoutStore.rows
    @State private var confirmArrange = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置")
                .font(.title3.weight(.semibold))

            // 唤起快捷键
            Picker("唤起快捷键", selection: $hotkey) {
                ForEach(HotkeyOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: hotkey) { _, newValue in
                Settings.hotkeyOption = newValue
                (NSApp.delegate as? AppDelegate)?.hotkeyChanged()
            }

            Divider()

            // 网格行列数(改动即时重排,超容部分向后页溢出)
            Stepper("每页列数:\(columns)", value: $columns, in: 5...10)
                .onChange(of: columns) { _, newValue in
                    Settings.columns = newValue
                    LayoutStore.columns = newValue
                    LayoutStore.shared.gridConfigChanged()
                }
            Stepper("每页行数:\(rows)", value: $rows, in: 3...8)
                .onChange(of: rows) { _, newValue in
                    Settings.rows = newValue
                    LayoutStore.rows = newValue
                    LayoutStore.shared.gridConfigChanged()
                }

            Divider()

            Button("按名称重新排列全部应用…") {
                confirmArrange = true
            }

            Text("布局数据保存在 ~/Library/Application Support/LaunchpadClone/")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("完成") { dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .alert("按名称重新排列?", isPresented: $confirmArrange) {
            Button("重新排列", role: .destructive) {
                LayoutStore.shared.arrangeAllByName()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将按显示名重排所有页面上的应用与文件夹,现有自定义顺序会被打乱(文件夹内容不变)。")
        }
    }
}
