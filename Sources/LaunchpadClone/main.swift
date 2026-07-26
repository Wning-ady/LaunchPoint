import AppKit
import SwiftUI
import Carbon.HIToolbox

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

    func flipPage(_ delta: Int) {
        let count = LayoutStore.shared.pages.count
        guard count > 0 else { return }
        currentPage = min(max(currentPage + delta, 0), count - 1)
        // 手动翻页后旧页高亮失效:防止方向键把视图拽回旧页、回车启动看不见的应用
        highlightedAppID = nil
    }
}

extension Notification.Name {
    /// 覆盖层重新显示时,通知 SwiftUI 重新聚焦搜索框。
    static let refocusSearch = Notification.Name("LaunchpadRefocusSearch")
}

/// 无边框窗口默认不能成为 key window,覆盖后搜索框才能接收键盘输入。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpWindow()
        setUpStatusItem()
        registerHotKey()
        setUpKeyMonitor()
        setUpScrollMonitor()
        showOverlay()
    }

    // MARK: - 覆盖层窗口

    private func setUpWindow() {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
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
        AppState.shared.query = ""
        AppState.shared.highlightedAppID = nil
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .refocusSearch, object: nil)
    }

    /// 关闭:隐藏待唤起(不退出),焦点还给之前的应用。
    func dismissOverlay() {
        window?.orderOut(nil)
        NSApp.hide(nil)
    }

    /// 重复执行唤起动作 = 关闭(与 LaunchOS 行为一致)。
    @objc func toggleOverlay() {
        if window?.isVisible == true {
            dismissOverlay()
        } else {
            showOverlay()
        }
    }

    // MARK: - 菜单栏图标

    private func setUpStatusItem() {
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

    /// 左键:唤起/关闭;右键:菜单(退出等)。
    @objc private func statusItemClicked() {
        guard let item = statusItem else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let toggle = NSMenuItem(title: "显示 / 隐藏启动台",
                                    action: #selector(toggleOverlay), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
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

    // MARK: - 全局快捷键 ⌥空格(Carbon API,无需辅助功能权限)

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.toggleOverlay()
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C50_434C), id: 1) // "LPCL"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: - 键盘

    private func setUpKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 输入法组字期间(拼音候选窗弹出)把所有按键让给输入法:
            // 方向键选候选字、回车上屏、Esc 取消组字都必须由 IME 处理
            if let editor = self?.window?.firstResponder as? NSTextView,
               editor.hasMarkedText() {
                return event
            }
            // Esc:搜索非空时先清空搜索,否则关闭(还原 LaunchOS 行为)。
            if event.keyCode == 53 { // Esc
                if AppState.shared.query.isEmpty {
                    self?.dismissOverlay()
                } else {
                    AppState.shared.query = ""
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
            // 回车(主键盘 36 / 小键盘 76):打开高亮应用;
            // 无高亮时放行给搜索框 onSubmit(打开第一个结果)
            if event.keyCode == 36 || event.keyCode == 76,
               let id = AppState.shared.highlightedAppID,
               let app = LayoutStore.shared.items.first(where: { $0.id == id }) {
                NSWorkspace.shared.open(app.url)
                self?.dismissOverlay()
                return nil
            }
            return event
        }
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
