import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

enum LaunchPointPhase {
    case hidden
    case visible
    case settings
    case folder
    case searching
    case dragging
}

/// 全局共享状态,让 AppKit 层(按键/滚轮监听)与 SwiftUI 层互通。
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var query = ""
    /// 去除首尾空白后的有效查询:误触空格不应切换搜索态或参与匹配。
    var effectiveQuery: String { query.trimmingCharacters(in: .whitespaces) }
    /// 当前页码。隐藏后不重置——还原"上次打开的位置"(原生默认行为)。
    @Published var currentPage = 0
    /// 键盘高亮的应用(id = 应用路径);nil = 无高亮。
    @Published var highlightedAppID: String?
    /// 是否正在拖拽图标(排序中)。
    @Published var isDragging = false
    /// 拖拽已被取消(Esc/隐藏/切搜索),同一次按住期间不得重新开始拖拽;松开鼠标后复位。
    var dragInhibited = false
    /// 当前展开的文件夹 id;nil = 未展开。
    @Published var openFolderID: String?
    /// 是否正在编辑文件夹标题(改名中):此时按键全部放行给输入框。
    var folderTitleEditing = false
    /// 设置面板是否打开(⌘, / 菜单入口)。
    @Published var showSettings = false
    @Published private(set) var phase: LaunchPointPhase = .hidden
    /// 覆盖层背景设置,由设置页实时修改。
    @Published var backgroundStyle = Settings.backgroundStyle
    @Published var blurWallpaper = Settings.blurWallpaper
    @Published var viewMode = Settings.viewMode
    /// 设置面板使用的即时预览值。持久布局在用户停手后再提交，避免 Stepper
    /// 连点时反复重建全部页面并写盘。
    @Published var gridColumns = Settings.columns
    @Published var gridRows = Settings.rows
    @Published var iconScale = Settings.iconScale
    @Published var horizontalSpacing = Settings.horizontalSpacing
    @Published var verticalSpacing = Settings.verticalSpacing

    func enterSettings() {
        withAnimation(.easeOut(duration: 0.16)) {
            showSettings = true
            phase = .settings
        }
    }

    func leaveSettings() {
        withAnimation(.easeOut(duration: 0.14)) {
            showSettings = false
            if phase == .settings { phase = .visible }
        }
    }

    func setOverlayVisible(_ visible: Bool) {
        if visible {
            phase = showSettings ? .settings : .visible
        } else {
            showSettings = false
            phase = .hidden
        }
    }

    func setBackgroundStyle(_ style: BackgroundStyle) {
        Settings.backgroundStyle = style
        backgroundStyle = style
    }

    func setBlurWallpaper(_ enabled: Bool) {
        Settings.blurWallpaper = enabled
        blurWallpaper = enabled
    }

    func previewGrid(columns: Int, rows: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            gridColumns = min(max(columns, 5), 10)
            gridRows = min(max(rows, 3), 8)
        }
    }

    func previewIconScale(_ scale: Double) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            iconScale = min(max(scale, Settings.minimumIconScale),
                            Settings.maximumIconScale)
        }
    }

    func previewSpacing(horizontal: Double, vertical: Double) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            horizontalSpacing = min(max(horizontal, Settings.minimumSpacing),
                                    Settings.maximumSpacing)
            verticalSpacing = min(max(vertical, Settings.minimumSpacing),
                                  Settings.maximumSpacing)
        }
    }

    func openFolder(_ id: String) {
        withAnimation(.easeOut(duration: 0.17)) {
            openFolderID = id
            phase = .folder
        }
    }

    func closeFolder() {
        withAnimation(.easeOut(duration: 0.14)) {
            openFolderID = nil
            if phase == .folder { phase = .visible }
        }
    }

    func flipPage(_ delta: Int) {
        var count = LayoutStore.shared.pages.count
        if isDragging { count += 1 }   // 拖拽时允许翻到末尾的承接新页
        guard count > 0 else { return }
        let destination = min(max(currentPage + delta, 0), count - 1)
        guard destination != currentPage else { return }
        withAnimation(.interactiveSpring(response: 0.29, dampingFraction: 0.92,
                                          blendDuration: 0.05)) {
            currentPage = destination
            // 手动翻页后旧页高亮失效:防止方向键把视图拽回旧页、回车启动看不见的应用
            highlightedAppID = nil
        }
    }
}

extension Notification.Name {
    /// 覆盖层重新显示时,通知 SwiftUI 重新聚焦搜索框。
    static let refocusSearch = Notification.Name("LaunchPointRefocusSearch")
    /// Esc 终止拖拽:通知 SwiftUI 取消进行中的图标拖拽。
    static let cancelDrag = Notification.Name("LaunchPointCancelDrag")
    /// 覆盖窗口切换显示器后刷新对应屏幕的桌面壁纸。
    static let launchPointScreenChanged = Notification.Name("LaunchPointScreenChanged")
}

/// 无边框窗口默认不能成为 key window,覆盖后搜索框才能接收键盘输入。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var scrollEventHandler: ((NSEvent) -> Bool)?
    var swipeEventHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !isKeyWindow { makeKey() }
        case .scrollWheel:
            if scrollEventHandler?(event) == true { return }
        case .swipe:
            if swipeEventHandler?(event) == true { return }
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// 让失活的全屏启动台接受首次右键。`acceptsFirstMouse` 是 NSView 的行为，
/// 放在 hosting view 上可让 SwiftUI 的 contextMenu 收到原始右键事件。
final class OverlayHostingView: NSHostingView<ContentView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI 的透明区域会让默认 hit test 返回 nil；回退到宿主视图，
    /// 使图标间隙、网格尾部和背景都保留一个真实的 AppKit 输入目标。
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: OverlayWindow?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var f4HotKeyRef: EventHotKeyRef?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hotCornerArmed = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimPrimaryInstance() else { return }
        Settings.migrateLegacySpacingDefaultsIfNeeded()
        // 把持久化设置注入布局层(布局层不直接依赖设置层,便于独立测试)
        LayoutStore.columns = Settings.columns
        LayoutStore.rows = Settings.rows
        setUpWindow()
        setUpStatusItem()
        registerHotKey()
        setUpKeyMonitor()
        setUpMouseUpMonitor()
        setUpHotCornerMonitor()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        showOverlay()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showOverlay()
        return true
    }

    /// 同一 bundle 标识只保留一个全屏覆盖窗口。重复打开时把焦点交还既有实例，
    /// 避免多个透明窗口互相抢占鼠标、滚轮和全局快捷键。
    private func claimPrimaryInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != currentPID
        }) {
            running.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    // MARK: - 覆盖层窗口

    private func setUpWindow() {
        let frame = selectedScreen().frame
        let window = OverlayWindow(contentRect: frame,
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false)
        window.level = .popUpMenu                      // 盖在普通窗口与 Dock 之上
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.scrollEventHandler = { [weak self] event in
            self?.handleScrollEvent(event) ?? false
        }
        window.swipeEventHandler = { [weak self] event in
            self?.handleSwipeEvent(event) ?? false
        }
        let hostingView = OverlayHostingView(
            rootView: ContentView(dismiss: { [weak self] in self?.dismissOverlay() })
        )
        window.contentView = hostingView
        self.window = window
    }

    /// 唤起:清空上次搜索与高亮、置顶显示、聚焦搜索框。
    func showOverlay() {
        guard let window else { return }
        let targetFrame = selectedScreen().frame
        if window.frame != targetFrame { window.setFrame(targetFrame, display: false) }
        AppState.shared.query = ""
        AppState.shared.highlightedAppID = nil
        AppState.shared.openFolderID = nil
        AppState.shared.setOverlayVisible(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .launchPointScreenChanged, object: nil)
        NotificationCenter.default.post(name: .refocusSearch, object: nil)
    }

    /// 关闭:隐藏待唤起(不退出),焦点还给之前的应用。拖拽中先取消拖拽,防状态泄漏。
    func dismissOverlay() {
        if AppState.shared.isDragging {
            AppState.shared.dragInhibited = true
            NotificationCenter.default.post(name: .cancelDrag, object: nil)
        }
        window?.orderOut(nil)
        AppState.shared.setOverlayVisible(false)
        NSApp.deactivate()
    }

    /// 点击桌面或切换到另一应用时，不能留下一个仍在最上层的透明覆盖窗口。
    /// 仅在窗口真的失去 key status 后收起；打开 SwiftUI context menu 不会触发这条路径。
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.window?.isVisible == true,
                  self.window?.isKeyWindow == false,
                  NSApp.isActive == false else { return }
            self.dismissOverlay()
        }
    }

    /// 菜单栏入口:在启动台内打开设置面板。
    @objc private func openSettings() {
        showSettingsWindow()
    }

    func showSettingsWindow() {
        if window?.isVisible != true { showOverlay() }
        AppState.shared.enterSettings()
    }

    /// 松开鼠标 = 一次按住结束,解除"拖拽已取消"的抑制。
    private func setUpMouseUpMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            AppState.shared.dragInhibited = false
            return event
        }
    }

    /// 重复执行唤起动作 = 关闭(与 LaunchPoint 行为一致)。
    /// 弹窗(重命名等)打开期间不响应:隐藏再唤起会破坏 sheet 的键盘焦点(假模态)。
    @objc func toggleOverlay() {
        guard window?.attachedSheet == nil else { return }
        if window?.isVisible == true {
            dismissOverlay()
        } else {
            showOverlay()
        }
    }

    // MARK: - 菜单栏图标

    private func setUpStatusItem() {
        guard Settings.showMenuBarIcon, statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3.fill",
                                   accessibilityDescription: "LaunchPoint")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// 设置修改菜单栏图标可见性后立即更新状态栏项目。
    func menuBarVisibilityChanged() {
        if Settings.showMenuBarIcon {
            setUpStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    /// 左键:唤起/关闭;右键:菜单(退出等)。
    @objc private func statusItemClicked() {
        guard let item = statusItem else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let toggle = NSMenuItem(title: "显示 / 隐藏启动台",
                                    action: #selector(toggleOverlay), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
            let settings = NSMenuItem(title: "设置…",
                                      action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出",
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(quit)
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil                            // 用完即卸,恢复左键直达
        } else {
            toggleOverlay()
        }
    }

    // MARK: - 全局快捷键(Carbon API,无需辅助功能权限;组合键可在设置中切换)

    private var hotKeyHandlerInstalled = false

    private func registerHotKey() {
        if !hotKeyHandlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.toggleOverlay()
                }
                return noErr
            }, 1, &eventType, nil, nil)
            hotKeyHandlerInstalled = true
        }
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
        let option = Settings.hotkeyOption
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C50_434C), id: 1) // "LPCL"
        RegisterEventHotKey(option.keyCode, option.modifiers,
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if let existing = f4HotKeyRef {
            UnregisterEventHotKey(existing)
            f4HotKeyRef = nil
        }
        if Settings.enableF4Shortcut {
            let f4ID = EventHotKeyID(signature: OSType(0x4C50_4634), id: 2)
            RegisterEventHotKey(UInt32(kVK_F4), 0, f4ID,
                                GetApplicationEventTarget(), 0, &f4HotKeyRef)
        }
    }

    /// 设置面板切换了快捷键组合:重新注册。
    func hotkeyChanged() {
        registerHotKey()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if #available(macOS 13.0, *) { try SMAppService.mainApp.register() }
            } else {
                if #available(macOS 13.0, *) { try SMAppService.mainApp.unregister() }
            }
        } catch {
            Settings.launchAtLogin = false
        }
    }

    // MARK: - 键盘

    private func setUpKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.window?.isKeyWindow == true else { return event }
            // 输入法组字期间(拼音候选窗弹出)把所有按键让给输入法:
            // 方向键选候选字、回车上屏、Esc 取消组字都必须由 IME 处理
            if let editor = self?.window?.firstResponder as? NSTextView,
               editor.hasMarkedText() {
                return event
            }
            // 弹窗(重命名对话框等)期间按键全部放行,回车/Esc 由弹窗自己处理
            if self?.window?.attachedSheet != nil {
                return event
            }
            // 设置面板拥有自己的方向键、回车和文本输入。Esc 是唯一由覆盖层
            // 接管的按键，且只关闭设置，不会把整个启动台一起隐藏。
            if AppState.shared.showSettings {
                if event.keyCode == 53 { // Esc
                    AppState.shared.leaveSettings()
                    return nil
                }
                return event
            }
            // Esc 层级:终止拖拽 > 关闭文件夹 > 清空搜索 > 关闭覆盖层(还原 LaunchPoint 行为)。
            if event.keyCode == 53 { // Esc
                if AppState.shared.isDragging {
                    NotificationCenter.default.post(name: .cancelDrag, object: nil)
                } else if AppState.shared.openFolderID != nil {
                    AppState.shared.closeFolder()
                } else if AppState.shared.query.isEmpty {
                    self?.dismissOverlay()
                } else {
                    AppState.shared.query = ""
                }
                return nil
            }
            // 拖拽中吞掉导航键:防止拖拽时回车开夹/启动应用造成状态交叠
            if AppState.shared.isDragging,
               [36, 76, 123, 124, 125, 126].contains(Int(event.keyCode)) {
                return nil
            }
            // ⌘, 打开设置(通用快捷键)
            if event.keyCode == 43, event.modifierFlags.contains(.command) {
                self?.showSettingsWindow()
                return nil
            }
            // 文件夹展开时的键盘策略(先于 ⌘翻页,保证面板下网格不动):
            // - 改名中:全部放行给标题输入框
            // - 方向键/回车/⌘组合:吞掉,防背景网格翻页误动
            // - 可打印字符:关闭文件夹并进入搜索(还原原生"打字即搜")
            if AppState.shared.openFolderID != nil {
                if AppState.shared.folderTitleEditing { return event }
                if [36, 76, 123, 124, 125, 126].contains(Int(event.keyCode))
                    || event.modifierFlags.contains(.command) {
                    return nil
                }
                if let chars = event.characters, !chars.isEmpty {
                    AppState.shared.closeFolder()
                    return event
                }
                return nil
            }
            // ⌘← / ⌘→ 翻页(还原原生启动台快捷键)
            if event.modifierFlags.contains(.command), AppState.shared.effectiveQuery.isEmpty {
                if event.keyCode == 123 { AppState.shared.flipPage(-1); return nil } // ←
                if event.keyCode == 124 { AppState.shared.flipPage(1); return nil }  // →
            }
            // 方向键:无修饰键时移动高亮(与原生一致,优先于搜索框文本光标);
            // ⇧/⌥/⌃ 修饰的方向键放行给文本框(选择文本、按词移动)
            let arrows: [UInt16: KeyboardNav.Direction] = [123: .left, 124: .right, 125: .down, 126: .up]
            if let direction = arrows[event.keyCode],
               event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                self?.moveHighlight(direction)
                return nil
            }
            // 回车(主键盘 36 / 小键盘 76):打开高亮的应用或文件夹;
            // 无高亮时放行给搜索框 onSubmit(打开第一个结果)
            if event.keyCode == 36 || event.keyCode == 76,
               let id = AppState.shared.highlightedAppID {
                if LayoutStore.shared.isFolderID(id) {
                    AppState.shared.openFolder(id)
                    return nil
                }
                if let app = LayoutStore.shared.items.first(where: { $0.id == id }) {
                    NSWorkspace.shared.open(app.url)
                    self?.dismissOverlay()
                    return nil
                }
            }
            return event
        }
    }

    private func selectedScreen() -> NSScreen {
        let fallback = NSScreen.main ?? NSScreen.screens.first!
        switch Settings.displayStrategy {
        case .main:
            return NSScreen.main ?? fallback
        case .active:
            return NSApp.keyWindow?.screen ?? NSScreen.main ?? fallback
        case .mouse:
            let point = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { $0.frame.contains(point) })
                ?? NSScreen.main ?? fallback
        }
    }

    /// 捕获主线程上的显示器与壁纸 URL，后台任务只处理不可变请求数据。
    func wallpaperLoadRequest() -> (urls: [URL], maxPixelSize: Int, cacheKey: String)? {
        let target = window?.screen ?? selectedScreen()
        let maxPointDimension = max(target.frame.width, target.frame.height)
        let pixels = maxPointDimension * target.backingScaleFactor
        let maxPixelSize = Int(min(max(pixels, 1024), 4096))

        let candidates = [target] + NSScreen.screens.filter { $0 !== target }
        var urls: [URL] = []
        var keys: [String] = []
        for screen in candidates {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  url.isFileURL,
                  FileManager.default.isReadableFile(atPath: url.path) else { continue }
            guard !urls.contains(url) else { continue }
            urls.append(url)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.stringValue ?? "?"
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            keys.append("\(url.path)|\(size)|\(modified)")
        }
        guard !urls.isEmpty else { return nil }
        return (urls, maxPixelSize, keys.joined(separator: ";") + "|\(maxPixelSize)")
    }

    func refreshSelectedScreen() {
        guard let window else { return }
        let frame = selectedScreen().frame
        if window.frame != frame {
            window.setFrame(frame, display: window.isVisible)
        }
        NotificationCenter.default.post(name: .launchPointScreenChanged, object: nil)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        refreshSelectedScreen()
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        refreshSelectedScreen()
    }

    // MARK: - 热角

    private func setUpHotCornerMonitor() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            DispatchQueue.main.async {
                self?.activateHotCornerIfNeeded()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.activateHotCornerIfNeeded()
            return event
        }
    }

    private func activateHotCornerIfNeeded() {
        let corner = Settings.hotCorner
        guard corner != .disabled, window?.isVisible != true else { return }

        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let frame = screen.frame
        let threshold: CGFloat = 3
        let isInCorner: Bool
        switch corner {
        case .disabled:
            isInCorner = false
        case .topLeft:
            isInCorner = point.x <= frame.minX + threshold && point.y >= frame.maxY - threshold
        case .topRight:
            isInCorner = point.x >= frame.maxX - threshold && point.y >= frame.maxY - threshold
        case .bottomLeft:
            isInCorner = point.x <= frame.minX + threshold && point.y <= frame.minY + threshold
        case .bottomRight:
            isInCorner = point.x >= frame.maxX - threshold && point.y <= frame.minY + threshold
        }

        if !isInCorner {
            hotCornerArmed = true
            return
        }
        guard hotCornerArmed else { return }
        hotCornerArmed = false
        showOverlay()
    }

    /// 方向键移动高亮:分页模式跨页时同步翻页;搜索模式在结果网格中移动。
    private func moveHighlight(_ direction: KeyboardNav.Direction) {
        let state = AppState.shared
        if state.effectiveQuery.isEmpty {
            if let result = KeyboardNav.move(pages: LayoutStore.shared.pages,
                                             columns: LayoutStore.columns,
                                             currentID: state.highlightedAppID,
                                             currentPage: state.currentPage,
                                             direction: direction) {
                state.highlightedAppID = result.id
                state.currentPage = result.page   // 高亮跨页时同步切页
            }
        } else {
            let results = SearchEngine.rank(state.effectiveQuery, in: LayoutStore.shared.items)
            if let id = KeyboardNav.move(items: results,
                                         columns: LayoutStore.columns,
                                         currentID: state.highlightedAppID,
                                         direction: direction) {
                state.highlightedAppID = id
            }
        }
    }

    private func canNavigatePages() -> Bool {
        window?.isVisible == true
            && window?.attachedSheet == nil
            && AppState.shared.showSettings == false
            && AppState.shared.viewMode == .paged
            && AppState.shared.openFolderID == nil
            && AppState.shared.isDragging == false
            && AppState.shared.effectiveQuery.isEmpty
    }

    /// 三指或系统手势滑动不会产生 scrollWheel；直接处理 AppKit swipe，
    /// 让图标间隙和任何起始位置都能翻页。
    private func handleSwipeEvent(_ event: NSEvent) -> Bool {
        guard canNavigatePages() else { return false }
        let horizontal = event.deltaX
        guard abs(horizontal) > abs(event.deltaY), horizontal != 0 else { return false }
        AppState.shared.flipPage(horizontal < 0 ? 1 : -1)
        return true
    }

    // MARK: - 滚轮翻页

    private var wheelAccumulatedDistance: CGFloat = 0
    private var wheelSessionDirection: CGFloat = 0
    private var wheelLastEventTimestamp: TimeInterval = 0
    private var wheelLastFlipTimestamp: TimeInterval = 0

    private func resetWheelSession() {
        wheelAccumulatedDistance = 0
        wheelSessionDirection = 0
        wheelLastEventTimestamp = 0
    }

    /// 直接由覆盖窗口分发滚轮，避免透明 SwiftUI 网格没有命中像素时，
    /// local monitor 收不到快速滚轮/触控板事件。
    private func handleScrollEvent(_ event: NSEvent) -> Bool {
        guard canNavigatePages() else {
            resetWheelSession()
            return false
        }

            let dx = event.scrollingDeltaX == 0 ? event.deltaX : event.scrollingDeltaX
            let dy = event.scrollingDeltaY == 0 ? event.deltaY : event.scrollingDeltaY
            let horizontalDistance = abs(dx)
            let verticalDistance = abs(dy)
            let delta: CGFloat
            if horizontalDistance > verticalDistance * 1.2 {
                delta = dx
            } else if verticalDistance > horizontalDistance * 1.2 {
                // 分页网格本身没有纵向滚动，普通鼠标滚轮也应能快速翻页。
                delta = dy
            } else {
                if event.phase == .ended || event.phase == .cancelled ||
                    event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    self.resetWheelSession()
                }
                return false
            }

            // 一次手势暂停后重新开始，反向时丢弃旧方向的残余，避免反向首帧跳页。
            if self.wheelLastEventTimestamp == 0 ||
                event.timestamp - self.wheelLastEventTimestamp > 0.65 {
                self.resetWheelSession()
            }
            let direction: CGFloat = delta < 0 ? -1 : 1
            if self.wheelSessionDirection != 0, self.wheelSessionDirection != direction {
                self.resetWheelSession()
            }
            self.wheelSessionDirection = direction
            self.wheelLastEventTimestamp = event.timestamp
            self.wheelAccumulatedDistance += abs(delta)

            // 精确设备的单帧增量很小，按距离累计；离散横向滚轮每一格都翻一页。
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 7 : 1
            guard wheelAccumulatedDistance >= threshold else { return true }

            // 惯性滚动会在一帧内送来大量事件。限制翻页频率，但继续消费本次
            // 手势，避免旧 spring 尚未落定时又堆入数个目标页动画。
            guard event.timestamp - wheelLastFlipTimestamp >= 0.18 else { return true }

            wheelAccumulatedDistance = 0
            wheelLastFlipTimestamp = event.timestamp
            AppState.shared.flipPage(direction < 0 ? 1 : -1)

            if event.phase == .ended || event.phase == .cancelled ||
                event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                resetWheelSession()
            }
            return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 覆盖层应用:不占 Dock、不切换菜单栏
let delegate = AppDelegate()
app.delegate = delegate
app.run()
