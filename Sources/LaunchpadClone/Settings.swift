import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

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

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case glass
    case wallpaper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "毛玻璃"
        case .wallpaper: return "系统壁纸"
        }
    }
}

enum LaunchViewMode: String, CaseIterable, Identifiable {
    case paged, scrolling
    var id: String { rawValue }
    var label: String { self == .paged ? "横向分页" : "纵向滚动" }
}

enum DisplayStrategy: String, CaseIterable, Identifiable {
    case main, active, mouse
    var id: String { rawValue }
    var label: String {
        switch self { case .main: return "主显示器"; case .active: return "当前活跃屏幕"; case .mouse: return "鼠标所在屏幕" }
    }
}

/// 指针抵达屏幕边角时唤起覆盖层；关闭状态表示不监听热角。
enum HotCorner: String, CaseIterable, Identifiable {
    case disabled
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: return "关闭"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
}

struct LayoutBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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

    static var backgroundStyle: BackgroundStyle {
        get { BackgroundStyle(rawValue: defaults.string(forKey: "BackgroundStyle") ?? "") ?? .glass }
        set { defaults.set(newValue.rawValue, forKey: "BackgroundStyle") }
    }

    static var blurWallpaper: Bool {
        get { defaults.object(forKey: "BlurWallpaper") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "BlurWallpaper") }
    }

    static var showMenuBarIcon: Bool {
        get { defaults.object(forKey: "ShowMenuBarIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ShowMenuBarIcon") }
    }

    static var enableF4Shortcut: Bool {
        get { defaults.object(forKey: "EnableF4Shortcut") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "EnableF4Shortcut") }
    }

    static var launchAtLogin: Bool {
        get { defaults.object(forKey: "LaunchAtLogin") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "LaunchAtLogin") }
    }

    static var viewMode: LaunchViewMode {
        get { LaunchViewMode(rawValue: defaults.string(forKey: "ViewMode") ?? "") ?? .paged }
        set { defaults.set(newValue.rawValue, forKey: "ViewMode") }
    }

    static var displayStrategy: DisplayStrategy {
        get { DisplayStrategy(rawValue: defaults.string(forKey: "DisplayStrategy") ?? "") ?? .main }
        set { defaults.set(newValue.rawValue, forKey: "DisplayStrategy") }
    }

    static var hotCorner: HotCorner {
        get { HotCorner(rawValue: defaults.string(forKey: "HotCorner") ?? "") ?? .disabled }
        set { defaults.set(newValue.rawValue, forKey: "HotCorner") }
    }
}

/// 独立设置窗口(⌘, 打开;修改即时生效)。
struct SettingsPanel: View {
    @State private var hotkey = Settings.hotkeyOption
    @State private var columns = LayoutStore.columns
    @State private var rows = LayoutStore.rows
    @State private var confirmArrange = false
    @State private var section: Section = .general
    @State private var backgroundStyle = Settings.backgroundStyle
    @State private var blurWallpaper = Settings.blurWallpaper
    @State private var showMenuBarIcon = Settings.showMenuBarIcon
    @State private var hotCorner = Settings.hotCorner
    @State private var backupDocument: LayoutBackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var dataMessage: String?
    @State private var sources = LayoutStore.shared.sourceRecords()
    @State private var showSourceImporter = false

    private enum Section: Hashable {
        case general
        case interface
        case apps
        case advanced
        case about
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                settingsTab(.general, title: "通用", symbol: "gearshape")
                settingsTab(.interface, title: "界面", symbol: "rectangle.3.group")
                settingsTab(.apps, title: "Apps", symbol: "square.stack.3d.up")
                settingsTab(.advanced, title: "高级", symbol: "slider.horizontal.3")
                settingsTab(.about, title: "关于", symbol: "info.circle")
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                Group {
                    switch section {
                    case .general:
                        generalSettings
                    case .interface:
                        interfaceSettings
                    case .apps:
                        appSettings
                    case .advanced:
                        advancedSettings
                    case .about:
                        aboutSettings
                    }
                }
                .padding(28)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("按名称重新排列?", isPresented: $confirmArrange) {
            Button("重新排列", role: .destructive) {
                LayoutStore.shared.arrangeAllByName()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将按显示名重排所有页面上的应用与文件夹，现有自定义顺序会被打乱，文件夹内容不变。")
        }
        .alert("布局数据", isPresented: Binding(
            get: { dataMessage != nil },
            set: { if !$0 { dataMessage = nil } }
        )) {
            Button("好", role: .cancel) { dataMessage = nil }
        } message: {
            Text(dataMessage ?? "")
        }
        .fileExporter(isPresented: $showExporter,
                      document: backupDocument,
                      contentType: .json,
                      defaultFilename: "LaunchpadClone-layout") { result in
            switch result {
            case .success:
                dataMessage = "布局备份已导出。"
            case .failure(let error):
                dataMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    try LayoutStore.shared.restoreBackup(Data(contentsOf: url))
                    dataMessage = "布局已恢复，并已与当前安装的应用对账。"
                } catch {
                    dataMessage = "恢复失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                dataMessage = "读取备份失败：\(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showSourceImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    LayoutStore.shared.addSource(path: url.path)
                }
                sources = LayoutStore.shared.sourceRecords()
            case .failure(let error):
                dataMessage = "添加应用来源失败：\(error.localizedDescription)"
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("启动")
                .font(.title3.weight(.semibold))

            settingCard {
                settingRow("开机启动", detail: "登录 macOS 后自动启动 LaunchpadClone") {
                    Toggle("开机启动", isOn: Binding(get: { Settings.launchAtLogin }, set: { value in
                        Settings.launchAtLogin = value
                        (NSApp.delegate as? AppDelegate)?.setLaunchAtLogin(value)
                    }))
                    .labelsHidden().toggleStyle(.switch)
                }

                Divider()

                settingRow("唤起快捷键", detail: "用于显示或隐藏启动台") {
                    Picker("唤起快捷键", selection: $hotkey) {
                        ForEach(HotkeyOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: hotkey) { _, newValue in
                        Settings.hotkeyOption = newValue
                        (NSApp.delegate as? AppDelegate)?.hotkeyChanged()
                    }
                }

                Divider()

                settingRow("显示菜单栏图标", detail: "隐藏后仍可使用快捷键唤起") {
                    Toggle("显示菜单栏图标", isOn: $showMenuBarIcon)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: showMenuBarIcon) { _, newValue in
                            Settings.showMenuBarIcon = newValue
                            (NSApp.delegate as? AppDelegate)?.menuBarVisibilityChanged()
                        }
                }

            }

            Text("快捷键修改后会立即生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("布局数据保存在 ~/Library/Application Support/LaunchpadClone/")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var layoutSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("布局")
                .font(.title3.weight(.semibold))

            settingCard {
                settingRow("显示模式", detail: "选择分页浏览或连续滚动") {
                    Picker("显示模式", selection: Binding(get: { Settings.viewMode }, set: { value in
                        Settings.viewMode = value
                        AppState.shared.viewMode = value
                    })) { ForEach(LaunchViewMode.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden().frame(width: 130)
                }

                Divider()

                settingRow("显示屏幕", detail: "启动台覆盖层显示在哪个屏幕") {
                    Picker("显示屏幕", selection: Binding(get: { Settings.displayStrategy }, set: { Settings.displayStrategy = $0 })) {
                        ForEach(DisplayStrategy.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 150)
                }

                Divider()

                settingRow("F4 快捷键", detail: "单独接管键盘 F4，和自定义快捷键并存") {
                    Toggle("F4 快捷键", isOn: Binding(get: { Settings.enableF4Shortcut }, set: { value in
                        Settings.enableF4Shortcut = value
                        (NSApp.delegate as? AppDelegate)?.hotkeyChanged()
                    })).labelsHidden().toggleStyle(.switch)
                }

                Divider()

                settingRow("热角", detail: "将指针移到指定屏幕的边角以显示启动台") {
                    Picker("热角", selection: $hotCorner) {
                        ForEach(HotCorner.allCases) { corner in
                            Text(corner.label).tag(corner)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: hotCorner) { _, newValue in
                        Settings.hotCorner = newValue
                    }
                }

                Divider()

                settingRow("每页列数", detail: "5 至 10 列") {
                    Stepper(value: $columns, in: 5...10) {
                        Text("\(columns) 列")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                    .onChange(of: columns) { _, newValue in
                        Settings.columns = newValue
                        LayoutStore.columns = newValue
                        LayoutStore.shared.gridConfigChanged()
                    }
                }

                Divider()
                    .padding(.leading, 0)

                settingRow("每页行数", detail: "3 至 8 行") {
                    Stepper(value: $rows, in: 3...8) {
                        Text("\(rows) 行")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                    .onChange(of: rows) { _, newValue in
                        Settings.rows = newValue
                        LayoutStore.rows = newValue
                        LayoutStore.shared.gridConfigChanged()
                    }
                }
            }

            Text("变更网格大小后，超出容量的项目会自动移到下一页。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("整理")
                .font(.title3.weight(.semibold))
                .padding(.top, 8)

            settingCard {
                settingRow("按名称重新排列", detail: "重新整理所有页面上的应用和文件夹") {
                    Button("重新排列…") {
                        confirmArrange = true
                    }
                }

                Divider()

                settingRow("整理空位", detail: "保持当前顺序，移除页面之间的空洞") {
                    Button("整理") {
                        LayoutStore.shared.fillEmptySlots()
                    }
                }
            }
            Spacer()
        }
    }

    private var interfaceSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            layoutSettings
            Divider()
            appearanceSettings
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            dataSettings
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("维护")
                    .font(.title3.weight(.semibold))
                settingCard {
                    settingRow("重新扫描应用", detail: "发现新安装的应用并清理已移除项目") {
                        Button("立即扫描") {
                            LayoutStore.shared.refreshAsync()
                        }
                    }
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LaunchpadClone")
                        .font(.title2.weight(.semibold))
                    Text("macOS 启动台替代方案")
                        .foregroundStyle(.secondary)
                }
            }
            settingCard {
                settingRow("版本", detail: "当前构建版本") {
                    Text("0.13")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Divider()
                settingRow("布局位置", detail: "本地保存的应用顺序与文件夹") {
                    Text("Application Support")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("快捷键、网格、背景和应用来源都可以在这里即时调整。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("背景")
                .font(.title3.weight(.semibold))

            settingCard {
                settingRow("类型", detail: "启动台打开时的背景效果") {
                    Picker("背景类型", selection: $backgroundStyle) {
                        ForEach(BackgroundStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: backgroundStyle) { _, newValue in
                        AppState.shared.setBackgroundStyle(newValue)
                    }
                }

                if backgroundStyle == .wallpaper {
                    Divider()
                    settingRow("模糊壁纸", detail: "让图标和文字更易辨识") {
                        Toggle("模糊壁纸", isOn: $blurWallpaper)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: blurWallpaper) { _, newValue in
                                AppState.shared.setBlurWallpaper(newValue)
                            }
                    }
                }
            }

            Text("系统壁纸会随 macOS 当前桌面背景更新。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("布局数据")
                .font(.title3.weight(.semibold))

            settingCard {
                settingRow("导出布局", detail: "备份应用顺序、文件夹、别名和隐藏状态") {
                    Button("导出…") {
                        do {
                            backupDocument = LayoutBackupDocument(data: try LayoutStore.shared.backupData())
                            showExporter = true
                        } catch {
                            dataMessage = "无法创建备份：\(error.localizedDescription)"
                        }
                    }
                }

                Divider()

                settingRow("恢复布局", detail: "恢复后会按本机已安装应用重新对账") {
                    Button("选择备份…") {
                        showImporter = true
                    }
                }
            }

            Text("备份文件使用 JSON 格式，可用于迁移或在调整布局前留存副本。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var appSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("应用来源")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    showSourceImporter = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                settingCard {
                    ForEach(sources.indices, id: \.self) { index in
                        let source = sources[index]
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: source.path).lastPathComponent)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Text(source.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Toggle("启用", isOn: Binding(
                                get: { sources[index].enabled },
                                set: { enabled in
                                    LayoutStore.shared.setSourceEnabled(source.path, enabled: enabled)
                                    sources = LayoutStore.shared.sourceRecords()
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            Button {
                                LayoutStore.shared.removeSource(path: source.path)
                                sources = LayoutStore.shared.sourceRecords()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("移除来源")
                        }
                        if index < sources.count - 1 {
                            Divider()
                        }
                    }
                }
            }

            Text("停用来源不会删除已有布局，只会停止扫描该目录中的应用。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func settingsTab(_ target: Section, title: String, symbol: String) -> some View {
        Button {
            section = target
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(width: 92, height: 70)
            .foregroundStyle(section == target ? Color.accentColor : Color.secondary)
            .background(section == target ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func settingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(16)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private func settingRow<Control: View>(_ title: String, detail: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
