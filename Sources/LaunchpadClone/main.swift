import AppKit
import SwiftUI
import Carbon.HIToolbox

/// 全局共享状态,让 AppKit 层(按键监听)与 SwiftUI 层互通。
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var query = ""
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
        setUpEscMonitor()
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

    /// 唤起:清空上次搜索、置顶显示、聚焦搜索框。
    func showOverlay() {
        guard let window else { return }
        AppState.shared.query = ""
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

    // MARK: - Esc

    private func setUpEscMonitor() {
        // Esc:搜索非空时先清空搜索,否则关闭(还原 LaunchOS 行为)。
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                if AppState.shared.query.isEmpty {
                    self?.dismissOverlay()
                } else {
                    AppState.shared.query = ""
                }
                return nil
            }
            return event
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 覆盖层应用:不占 Dock、不切换菜单栏
let delegate = AppDelegate()
app.delegate = delegate
app.run()
