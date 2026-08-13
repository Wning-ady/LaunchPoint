import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

private final class SettingsDragHandleView: NSView {
    var dragChanged: ((CGSize) -> Void)?
    var dragEnded: ((CGSize) -> Void)?
    private var originInWindow: NSPoint?

    override func mouseDown(with event: NSEvent) {
        originInWindow = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let originInWindow else { return }
        dragChanged?(translation(from: originInWindow, to: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard let originInWindow else { return }
        dragEnded?(translation(from: originInWindow, to: event.locationInWindow))
        self.originInWindow = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    private func translation(from start: NSPoint, to current: NSPoint) -> CGSize {
        CGSize(width: current.x - start.x, height: start.y - current.y)
    }
}

private struct SettingsDragHandle: NSViewRepresentable {
    let dragChanged: (CGSize) -> Void
    let dragEnded: (CGSize) -> Void

    func makeNSView(context: Context) -> SettingsDragHandleView {
        let view = SettingsDragHandleView()
        view.dragChanged = dragChanged
        view.dragEnded = dragEnded
        return view
    }

    func updateNSView(_ nsView: SettingsDragHandleView, context: Context) {
        nsView.dragChanged = dragChanged
        nsView.dragEnded = dragEnded
    }
}

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

/// 边缘双指使用公开滚动事件；四指/五指聚拢与扩散使用原始触点帧。
enum TrackpadShortcut: String, CaseIterable, Identifiable {
    case disabled
    case leftEdgeHorizontal
    case rightEdgeHorizontal
    case bottomEdgeVertical
    case topEdgeVertical
    case fourFingerPinchIn
    case fiveFingerPinchIn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: return "关闭"
        case .leftEdgeHorizontal: return "左边缘横滑"
        case .rightEdgeHorizontal: return "右边缘横滑"
        case .bottomEdgeVertical: return "底部纵滑"
        case .topEdgeVertical: return "顶部纵滑"
        case .fourFingerPinchIn: return "四指聚拢 / 扩散"
        case .fiveFingerPinchIn: return "五指聚拢 / 扩散"
        }
    }

    var helpText: String {
        switch self {
        case .disabled:
            return "关闭触控板唤起"
        case .leftEdgeHorizontal, .rightEdgeHorizontal, .bottomEdgeVertical,
                .topEdgeVertical:
            return "在屏幕边缘双指滑动，不占用系统三指或四指手势"
        case .fourFingerPinchIn, .fiveFingerPinchIn:
            return "聚拢显示，扩散隐藏；只观察手势，不拦截系统操作"
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

/// 用户设置(UserDefaults 持久化)。
enum Settings {
    private static let defaults = UserDefaults.standard
    static let minimumIconScale = 0.5
    static let maximumIconScale = 1.8
    static let minimumSpacing = 4.0
    static let maximumSpacing = 80.0
    static let defaultSpacing = 18.0

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

    /// 图标比例只影响网格的视觉尺寸，不改变每页的容量。
    static var iconScale: Double {
        get {
            let value = defaults.object(forKey: "GridIconScale") as? Double ?? 1
            return min(max(value, minimumIconScale), maximumIconScale)
        }
        set {
            defaults.set(min(max(newValue, minimumIconScale), maximumIconScale),
                         forKey: "GridIconScale")
        }
    }

    static var horizontalSpacing: Double {
        get {
            let value = defaults.object(forKey: "GridHorizontalSpacing") as? Double ?? defaultSpacing
            return min(max(value, minimumSpacing), maximumSpacing)
        }
        set {
            defaults.set(min(max(newValue, minimumSpacing), maximumSpacing),
                         forKey: "GridHorizontalSpacing")
        }
    }

    static var verticalSpacing: Double {
        get {
            let value = defaults.object(forKey: "GridVerticalSpacing") as? Double ?? defaultSpacing
            return min(max(value, minimumSpacing), maximumSpacing)
        }
        set {
            defaults.set(min(max(newValue, minimumSpacing), maximumSpacing),
                         forKey: "GridVerticalSpacing")
        }
    }

    /// Move untouched legacy defaults forward while preserving custom spacing.
    static func migrateLegacySpacingDefaultsIfNeeded() {
        let version = defaults.integer(forKey: "GridSpacingDefaultsVersion")
        guard version < 2 else { return }

        if version < 1,
           defaults.object(forKey: "GridHorizontalSpacing") as? Double == 16,
           defaults.object(forKey: "GridVerticalSpacing") as? Double == 20 {
            defaults.set(12.0, forKey: "GridHorizontalSpacing")
            defaults.set(12.0, forKey: "GridVerticalSpacing")
        }

        let horizontal = defaults.object(forKey: "GridHorizontalSpacing") as? Double
        let vertical = defaults.object(forKey: "GridVerticalSpacing") as? Double
        if horizontal == 12, vertical == 12 {
            defaults.set(defaultSpacing, forKey: "GridHorizontalSpacing")
            defaults.set(defaultSpacing, forKey: "GridVerticalSpacing")
        }
        defaults.set(2, forKey: "GridSpacingDefaultsVersion")
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

    static var trackpadShortcut: TrackpadShortcut {
        get {
            TrackpadShortcut(rawValue: defaults.string(forKey: "TrackpadShortcut") ?? "")
                ?? .disabled
        }
        set { defaults.set(newValue.rawValue, forKey: "TrackpadShortcut") }
    }
}

/// 独立设置窗口(⌘, 打开;修改即时生效)。
struct SettingsPanel: View {
    let close: () -> Void
    let dragChanged: (CGSize) -> Void
    let dragEnded: (CGSize) -> Void
    @State private var hotkey = Settings.hotkeyOption
    @State private var columns = AppState.shared.gridColumns
    @State private var rows = AppState.shared.gridRows
    @State private var iconScale = AppState.shared.iconScale
    @State private var horizontalSpacing = AppState.shared.horizontalSpacing
    @State private var verticalSpacing = AppState.shared.verticalSpacing
    @State private var confirmArrange = false
    @State private var section: Section = .general
    @State private var backgroundStyle = Settings.backgroundStyle
    @State private var blurWallpaper = Settings.blurWallpaper
    @State private var showMenuBarIcon = Settings.showMenuBarIcon
    @State private var hotCorner = Settings.hotCorner
    @State private var trackpadShortcut = Settings.trackpadShortcut
    @ObservedObject private var appState = AppState.shared
    @State private var backupDocument: LayoutBackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var dataMessage: String?
    @State private var sources = LayoutStore.shared.sourceRecords()
    @State private var showSourceImporter = false
    @State private var customApps = LayoutStore.shared.customAppPaths()
    @State private var showProgramImporter = false
    @State private var isHoveringTitleBar = false
    @StateObject private var updateChecker = UpdateChecker()
    @State private var gridCommitWork: DispatchWorkItem?
    @State private var iconCommitWork: DispatchWorkItem?
    @State private var spacingCommitWork: DispatchWorkItem?
    @State private var iconPreviewWork: DispatchWorkItem?
    @State private var spacingPreviewWork: DispatchWorkItem?
    @State private var gridNeedsCommit = false
    @State private var iconNeedsCommit = false
    @State private var spacingNeedsCommit = false
    @State private var gridCommitGeneration = 0
    @State private var iconCommitGeneration = 0
    @State private var spacingCommitGeneration = 0
    @State private var iconPreviewGeneration = 0
    @State private var spacingPreviewGeneration = 0

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
                draggableTitleRegion {
                    HStack(spacing: 10) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(sectionTint(section))
                    Text("LaunchPoint 设置")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    }
                }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.secondaryText)
                .background(AppTheme.subtleFill, in: Circle())
                .help("关闭设置")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(titleBarBackground)

            HStack(spacing: 6) {
                settingsTab(.general, title: "通用", symbol: "gearshape")
                settingsTab(.interface, title: "界面", symbol: "rectangle.3.group")
                settingsTab(.apps, title: "Apps", symbol: "square.stack.3d.up")
                settingsTab(.advanced, title: "高级", symbol: "slider.horizontal.3")
                settingsTab(.about, title: "关于", symbol: "info.circle")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
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
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .frame(width: 560, height: 440)
        .foregroundStyle(AppTheme.charcoal)
        .tint(AppTheme.blue)
        .environment(\.colorScheme, .light)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.separator, lineWidth: 1))
        .shadow(color: AppTheme.charcoal.opacity(0.2), radius: 22, y: 9)
        .onDisappear {
            flushPendingPreview()
            updateChecker.cancel()
        }
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
                      defaultFilename: "LaunchPoint-layout") { result in
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
        .fileImporter(isPresented: $showProgramImporter,
                      allowedContentTypes: [.application, .unixExecutable],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var added = 0
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if LayoutStore.shared.addCustomApp(path: url.path) { added += 1 }
                }
                customApps = LayoutStore.shared.customAppPaths()
                if added == 0 {
                    dataMessage = "请选择应用包或可执行文件。"
                }
            case .failure(let error):
                dataMessage = "添加程序失败：\(error.localizedDescription)"
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("启动")
                .font(.title3.weight(.semibold))

            settingCard {
                settingRow("开机启动", detail: "登录 macOS 后自动启动 LaunchPoint") {
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

                settingRow("触控板唤起", detail: trackpadShortcut.helpText) {
                    Picker("触控板唤起", selection: $trackpadShortcut) {
                        ForEach(TrackpadShortcut.allCases) { shortcut in
                            Text(shortcut.label).tag(shortcut)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: trackpadShortcut) { _, newValue in
                        Settings.trackpadShortcut = newValue
                        (NSApp.delegate as? AppDelegate)?.trackpadShortcutChanged()
                    }
                }

                if trackpadUsesRawContacts {
                    Divider()
                    settingRow("多指监听", detail: trackpadMonitorDetail) {
                        HStack(spacing: 8) {
                            if appState.trackpadMonitorStatus == .connecting {
                                ProgressView().controlSize(.small)
                            }
                            if appState.trackpadMonitorStatus == .unavailable {
                                Button("重新连接") {
                                    (NSApp.delegate as? AppDelegate)?.retryRawTrackpadMonitor()
                                }
                            } else {
                                Image(systemName: trackpadMonitorSymbol)
                                    .foregroundStyle(trackpadMonitorTint)
                            }
                        }
                    }

                    Divider()
                    settingRow("触点诊断", detail: trackpadContactDetail) {
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("\(appState.rawTrackpadContactCount) 指")
                                .font(.body.monospacedDigit().weight(.medium))
                                .foregroundStyle(appState.rawTrackpadContactCount > 0
                                                 ? AppTheme.blue : AppTheme.secondaryText)
                            ProgressView(value: abs(appState.rawTrackpadPinchProgress))
                                .progressViewStyle(.linear)
                                .tint(AppTheme.blue)
                                .frame(width: 112)
                        }
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
            Text("布局数据保存在 ~/Library/Application Support/LaunchPoint/")
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
                    Picker("显示屏幕", selection: Binding(get: { Settings.displayStrategy }, set: {
                        Settings.displayStrategy = $0
                        (NSApp.delegate as? AppDelegate)?.refreshSelectedScreen()
                    })) {
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
                    Stepper(value: gridColumnsBinding, in: 5...10) {
                        Text("\(columns) 列")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Divider()
                    .padding(.leading, 0)

                settingRow("每页行数", detail: "3 至 8 行") {
                    Stepper(value: gridRowsBinding, in: 3...8) {
                        Text("\(rows) 行")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Divider()

                settingRow("图标大小", detail: "只调整图标的视觉比例") {
                    VStack(alignment: .trailing, spacing: 3) {
                        Slider(value: iconScaleBinding,
                               in: Settings.minimumIconScale...Settings.maximumIconScale,
                               step: 0.05)
                            .frame(width: 118)
                        Text("\(Int((iconScale * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("图标大小")
                }

                Divider()

                settingRow("横向间距", detail: "调整同一行图标之间的距离") {
                    spacingSlider(value: horizontalSpacingBinding,
                                  displayValue: Int(horizontalSpacing.rounded()))
                }

                Divider()

                settingRow("纵向间距", detail: "调整相邻两行图标之间的距离") {
                    spacingSlider(value: verticalSpacingBinding,
                                  displayValue: Int(verticalSpacing.rounded()))
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("LaunchPoint")
                        .font(.title2.weight(.semibold))
                    Text("简洁、快速的 macOS 应用启动器")
                        .foregroundStyle(.secondary)
                }
            }
            settingCard {
                settingRow("版本", detail: "当前构建版本") {
                    Text(displayCurrentVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Divider()
                settingRow("检查更新", detail: updateStatusDetail) {
                    HStack(spacing: 8) {
                        if updateChecker.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button(updateCheckButtonTitle) {
                            updateChecker.checkForUpdates()
                        }
                        .disabled(isCheckingForUpdates)
                    }
                }
                if let release = updateChecker.availableRelease {
                    Divider()
                    settingRow("发现新版本", detail: release.version) {
                        Button("自动更新") {
                            updateChecker.installAvailableUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updateChecker.isBusy)
                    }
                    Divider()
                    settingRow("发行版页面", detail: "自动更新失败时可手动下载") {
                        Button("打开") {
                            NSWorkspace.shared.open(release.releaseURL)
                        }
                    }
                }
                Divider()
                settingRow("开源地址", detail: "查看源代码、发行版和问题反馈") {
                    Button {
                        NSWorkspace.shared.open(UpdateChecker.repositoryURL)
                    } label: {
                        Label("GitHub", systemImage: "arrow.up.right.square")
                    }
                }
            }
            Text("LaunchPoint 由 AI 完整生成和实现，未来版本通过 GitHub Releases 发布。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var isCheckingForUpdates: Bool {
        updateChecker.isBusy
    }

    private var trackpadUsesRawContacts: Bool {
        trackpadShortcut == .fourFingerPinchIn || trackpadShortcut == .fiveFingerPinchIn
    }

    private var trackpadMonitorDetail: String {
        switch appState.trackpadMonitorStatus {
        case .inactive:
            return "监听尚未启动"
        case .connecting:
            return "正在连接触控板"
        case .connected(let fingerCount):
            return "已连接，正在识别 \(fingerCount) 指聚拢与扩散"
        case .unavailable:
            return "无法连接原始触控板，请重新连接或使用边缘双指"
        }
    }

    private var trackpadMonitorSymbol: String {
        switch appState.trackpadMonitorStatus {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "clock"
        case .inactive: return "pause.circle"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private var trackpadContactDetail: String {
        if let date = appState.rawTrackpadLastTriggerAt {
            return "已触发 \(appState.rawTrackpadTriggerCount) 次，最近于 \(date.formatted(date: .omitted, time: .standard))"
        }
        if appState.rawTrackpadContactCount > 0 {
            let progress = appState.rawTrackpadPinchProgress
            let percent = Int((abs(progress) * 100).rounded())
            let direction = progress < 0 ? "扩散" : "聚拢"
            return "正在接收原始触点，\(direction)进度 \(percent)%"
        }
        return "触摸板静止；放上手指后数字会实时变化"
    }

    private var trackpadMonitorTint: Color {
        switch appState.trackpadMonitorStatus {
        case .connected: return .green
        case .unavailable: return .orange
        case .inactive, .connecting: return .secondary
        }
    }

    private var displayCurrentVersion: String {
        updateChecker.currentVersion.lowercased().hasPrefix("v")
            ? updateChecker.currentVersion
            : "v\(updateChecker.currentVersion)"
    }

    private var updateCheckButtonTitle: String {
        switch updateChecker.state {
        case .checking: return "检查中"
        case .downloading: return "下载中"
        case .installing: return "安装中"
        case .updateAvailable: return "重新检查"
        default: return "检查更新"
        }
    }

    private var updateStatusDetail: String {
        switch updateChecker.state {
        case .idle:
            return "从 GitHub Releases 获取最新版本"
        case .checking:
            return "正在连接 GitHub"
        case .downloading(let version):
            return "正在下载 \(version)"
        case .installing(let version):
            return "正在安装 \(version)，完成后会自动重启"
        case .upToDate(let latestVersion):
            return "已是最新版本（\(latestVersion)）"
        case .updateAvailable(let release):
            return "可更新到 \(release.version)"
        case .failed(let message):
            return message
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
                    .pickerStyle(.segmented)
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

            settingCard {
                if sources.isEmpty {
                    Text("还没有添加应用来源。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(sources, id: \.path) { source in
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
                            get: { sources.first(where: { $0.path == source.path })?.enabled ?? source.enabled },
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
                    if source.path != sources.last?.path {
                        Divider()
                    }
                }
            }

            Text("停用来源不会删除已有布局，只会停止扫描该目录中的应用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            HStack {
                Text("手动添加程序")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    showProgramImporter = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            settingCard {
                if customApps.isEmpty {
                    Text("可添加任意应用包或可执行文件。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(customApps, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(systemName: "terminal")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button {
                            LayoutStore.shared.removeCustomApp(path: path)
                            customApps = LayoutStore.shared.customAppPaths()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("移除程序")
                    }
                    if path != customApps.last {
                        Divider()
                    }
                }
            }
            Spacer()
        }
    }

    private func settingsTab(_ target: Section, title: String, symbol: String) -> some View {
        Button {
            section = target
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(section == target ? sectionTint(target) : AppTheme.secondaryText)
            .background(section == target ? sectionTint(target).opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// 只有标题和明确的空白区域接收拖动，标签与关闭按钮保留独立点击。
    private func draggableTitleRegion<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .overlay(SettingsDragHandle(dragChanged: dragChanged, dragEnded: dragEnded))
            .help("拖动设置窗口")
    }

    private var titleBarBackground: some View {
        Rectangle()
            .fill(isHoveringTitleBar ? AppTheme.subtleFill : Color.clear)
            .animation(.easeOut(duration: 0.14), value: isHoveringTitleBar)
            .allowsHitTesting(false)
    }

    private func sectionTint(_ target: Section) -> Color {
        _ = target
        return AppTheme.blue
    }

    private var gridColumnsBinding: Binding<Int> {
        Binding(
            get: { columns },
            set: { updateGrid(columns: $0, rows: rows) }
        )
    }

    private var gridRowsBinding: Binding<Int> {
        Binding(
            get: { rows },
            set: { updateGrid(columns: columns, rows: $0) }
        )
    }

    private var iconScaleBinding: Binding<Double> {
        Binding(
            get: { iconScale },
            set: { newValue in
                let bounded = min(max(newValue, Settings.minimumIconScale),
                                  Settings.maximumIconScale)
                guard iconScale != bounded else { return }
                iconScale = bounded
                scheduleIconPreview(bounded)
                iconNeedsCommit = true
                iconCommitWork?.cancel()
                iconCommitGeneration &+= 1
                let generation = iconCommitGeneration
                let work = DispatchWorkItem {
                    guard generation == iconCommitGeneration else { return }
                    Settings.iconScale = bounded
                    iconNeedsCommit = false
                }
                iconCommitWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
            }
        )
    }

    private var horizontalSpacingBinding: Binding<Double> {
        Binding(
            get: { horizontalSpacing },
            set: { updateSpacing(horizontal: $0, vertical: verticalSpacing) }
        )
    }

    private var verticalSpacingBinding: Binding<Double> {
        Binding(
            get: { verticalSpacing },
            set: { updateSpacing(horizontal: horizontalSpacing, vertical: $0) }
        )
    }

    private func spacingSlider(value: Binding<Double>, displayValue: Int) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Slider(value: value,
                   in: Settings.minimumSpacing...Settings.maximumSpacing,
                   step: 1)
                .frame(width: 118)
            Text("\(displayValue) pt")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func updateSpacing(horizontal: Double, vertical: Double) {
        let boundedHorizontal = min(max(horizontal, Settings.minimumSpacing),
                                    Settings.maximumSpacing)
        let boundedVertical = min(max(vertical, Settings.minimumSpacing),
                                  Settings.maximumSpacing)
        guard horizontalSpacing != boundedHorizontal || verticalSpacing != boundedVertical else {
            return
        }
        horizontalSpacing = boundedHorizontal
        verticalSpacing = boundedVertical
        scheduleSpacingPreview(horizontal: boundedHorizontal, vertical: boundedVertical)
        spacingNeedsCommit = true
        spacingCommitWork?.cancel()
        spacingCommitGeneration &+= 1
        let generation = spacingCommitGeneration
        let work = DispatchWorkItem {
            guard generation == spacingCommitGeneration else { return }
            Settings.horizontalSpacing = boundedHorizontal
            Settings.verticalSpacing = boundedVertical
            spacingNeedsCommit = false
        }
        spacingCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    /// 行列变化直接提交给展示模型，因此开启设置面板时底层网格立即重排。
    private func updateGrid(columns newColumns: Int, rows newRows: Int) {
        let boundedColumns = min(max(newColumns, 5), 10)
        let boundedRows = min(max(newRows, 3), 8)
        guard columns != boundedColumns || rows != boundedRows else { return }
        columns = boundedColumns
        rows = boundedRows
        AppState.shared.previewGrid(columns: boundedColumns, rows: boundedRows)
        gridNeedsCommit = true
        gridCommitWork?.cancel()
        gridCommitGeneration &+= 1
        let generation = gridCommitGeneration
        let work = DispatchWorkItem {
            guard generation == gridCommitGeneration else { return }
            commitGrid(columns: boundedColumns, rows: boundedRows)
            gridNeedsCommit = false
        }
        gridCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func commitGrid(columns: Int, rows: Int) {
        Settings.columns = columns
        Settings.rows = rows
        LayoutStore.columns = columns
        LayoutStore.rows = rows
        LayoutStore.shared.gridConfigChanged()
    }

    /// Coalesce continuous slider events to at most one grid layout per frame.
    private func scheduleIconPreview(_ scale: Double) {
        iconPreviewWork?.cancel()
        iconPreviewGeneration &+= 1
        let generation = iconPreviewGeneration
        let work = DispatchWorkItem {
            guard generation == iconPreviewGeneration else { return }
            AppState.shared.previewIconScale(scale)
        }
        iconPreviewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
    }

    private func scheduleSpacingPreview(horizontal: Double, vertical: Double) {
        spacingPreviewWork?.cancel()
        spacingPreviewGeneration &+= 1
        let generation = spacingPreviewGeneration
        let work = DispatchWorkItem {
            guard generation == spacingPreviewGeneration else { return }
            AppState.shared.previewSpacing(horizontal: horizontal, vertical: vertical)
        }
        spacingPreviewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
    }

    private func flushPendingPreview() {
        gridCommitGeneration &+= 1
        iconCommitGeneration &+= 1
        spacingCommitGeneration &+= 1
        iconPreviewGeneration &+= 1
        spacingPreviewGeneration &+= 1
        gridCommitWork?.cancel()
        iconCommitWork?.cancel()
        spacingCommitWork?.cancel()
        iconPreviewWork?.cancel()
        spacingPreviewWork?.cancel()
        if gridNeedsCommit { commitGrid(columns: columns, rows: rows) }
        if iconNeedsCommit {
            AppState.shared.previewIconScale(iconScale)
            Settings.iconScale = iconScale
        }
        if spacingNeedsCommit {
            AppState.shared.previewSpacing(horizontal: horizontalSpacing, vertical: verticalSpacing)
            Settings.horizontalSpacing = horizontalSpacing
            Settings.verticalSpacing = verticalSpacing
        }
    }

    private func settingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(12)
            .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.separator, lineWidth: 1))
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
