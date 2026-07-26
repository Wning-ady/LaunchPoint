import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

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
    /// 覆盖层背景设置,由设置页实时修改。
    @Published var backgroundStyle = Settings.backgroundStyle
    @Published var blurWallpaper = Settings.blurWallpaper
    @Published var viewMode = Settings.viewMode

    func setBackgroundStyle(_ style: BackgroundStyle) {
        Settings.backgroundStyle = style
        backgroundStyle = style
    }

    func setBlurWallpaper(_ enabled: Bool) {
        Settings.blurWallpaper = enabled
        blurWallpaper = enabled
    }

    func flipPage(_ delta: Int) {
        var count = LayoutStore.shared.pages.count
        if isDragging { count += 1 }   // 拖拽时允许翻到末尾的承接新页
        guard count > 0 else { return }
        withAnimation(.interactiveSpring(response: 0.48, dampingFraction: 0.88,
                                          blendDuration: 0.16)) {
            currentPage = min(max(currentPage + delta, 0), count - 1)
            // 手动翻页后旧页高亮失效:防止方向键把视图拽回旧页、回车启动看不见的应用
            highlightedAppID = nil
        }
    }
}

extension Notification.Name {
    /// 覆盖层重新显示时,通知 SwiftUI 重新聚焦搜索框。
    static let refocusSearch = Notification.Name("LaunchpadRefocusSearch")
    /// Esc 终止拖拽:通知 SwiftUI 取消进行中的图标拖拽。
    static let cancelDrag = Notification.Name("LaunchpadCancelDrag")
}

/// 无边框窗口默认不能成为 key window,覆盖后搜索框才能接收键盘输入。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var f4HotKeyRef: EventHotKeyRef?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hotCornerArmed = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 把持久化设置注入布局层(布局层不直接依赖设置层,便于独立测试)
        LayoutStore.columns = Settings.columns
        LayoutStore.rows = Settings.rows
        setUpWindow()
        setUpStatusItem()
        registerHotKey()
        setUpKeyMonitor()
        setUpScrollMonitor()
        setUpMouseUpMonitor()
        setUpHotCornerMonitor()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        showOverlay()
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
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: ContentView(dismiss: { [weak self] in self?.dismissOverlay() })
        )
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .refocusSearch, object: nil)
    }

    /// 关闭:隐藏待唤起(不退出),焦点还给之前的应用。拖拽中先取消拖拽,防状态泄漏。
    func dismissOverlay() {
        if AppState.shared.isDragging {
            AppState.shared.dragInhibited = true
            NotificationCenter.default.post(name: .cancelDrag, object: nil)
        }
        window?.orderOut(nil)
        NSApp.hide(nil)
    }

    /// 菜单栏入口:打开独立设置窗口。
    @objc private func openSettings() {
        showSettingsWindow()
    }

    func showSettingsWindow() {
        dismissOverlay()
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered,
                             defer: false)
        panel.title = "LaunchpadClone 设置"
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.center()
        panel.contentView = NSHostingView(rootView: SettingsPanel())
        settingsWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 松开鼠标 = 一次按住结束,解除"拖拽已取消"的抑制。
    private func setUpMouseUpMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            AppState.shared.dragInhibited = false
            return event
        }
    }

    /// 重复执行唤起动作 = 关闭(与 LaunchOS 行为一致)。
    /// 弹窗(重命名等)打开期间不响应:隐藏再唤起会破坏 sheet 的键盘焦点(假模态)。
    @objc func toggleOverlay() {
        guard window?.attachedSheet == nil,
              settingsWindow?.isVisible != true else { return }
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
                                   accessibilityDescription: "Launchpad")
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
            // 设置窗口是独立原生窗口，不让启动台的全局监听器拦截其控件输入。
            if self?.settingsWindow?.isKeyWindow == true { return event }
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
            // Esc 层级:终止拖拽 > 关闭文件夹 > 清空搜索 > 关闭覆盖层(还原 LaunchOS 行为)。
            if event.keyCode == 53 { // Esc
                if AppState.shared.isDragging {
                    NotificationCenter.default.post(name: .cancelDrag, object: nil)
                } else if AppState.shared.openFolderID != nil {
                    AppState.shared.openFolderID = nil
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
                    AppState.shared.openFolderID = nil
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
                    AppState.shared.openFolderID = id
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

    @objc private func screenParametersChanged(_ notification: Notification) {
        guard let window else { return }
        let frame = selectedScreen().frame
        if window.frame != frame {
            window.setFrame(frame, display: window.isVisible)
        }
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

    // MARK: - 滚轮翻页

    private var lastWheelFlip = Date.distantPast

    /// 滚轮/触控板翻页。一次滚动只翻一页:
    /// 用冷却时间挡掉平滑滚轮与惯性滚动带来的连续触发(LaunchOS 也专门优化过这点)。
    private func setUpScrollMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  self.window?.isVisible == true,
                  self.window?.attachedSheet == nil,            // 弹窗期间不翻页
                  AppState.shared.openFolderID == nil,          // 文件夹展开时不翻页
                  AppState.shared.effectiveQuery.isEmpty else { return event } // 搜索结果照常滚动

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let delta = abs(dx) > abs(dy) ? dx : dy
            // 触控板/平滑滚轮的增量细腻,阈值高一些;分级滚轮一格就该翻
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 25 : 3

            if abs(delta) >= threshold,
               Date().timeIntervalSince(self.lastWheelFlip) > 0.35 {
                self.lastWheelFlip = Date()
                AppState.shared.flipPage(delta < 0 ? 1 : -1)
            }
            return nil
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 覆盖层应用:不占 Dock、不切换菜单栏
let delegate = AppDelegate()
app.delegate = delegate
app.run()
