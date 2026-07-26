import AppKit
import SwiftUI

/// 全局共享状态,让 AppKit 层(按键监听)与 SwiftUI 层互通。
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var query = ""
}

/// 无边框窗口默认不能成为 key window,覆盖后搜索框才能接收键盘输入。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = OverlayWindow(contentRect: frame,
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false)
        window.level = .popUpMenu                      // 盖在普通窗口与 Dock 之上
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: ContentView(dismiss: Self.dismiss))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        // Esc:搜索非空时先清空搜索,否则关闭(还原 LaunchOS 行为)。
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                if AppState.shared.query.isEmpty {
                    Self.dismiss()
                } else {
                    AppState.shared.query = ""
                }
                return nil
            }
            return event
        }
    }

    /// 阶段 2 加入菜单栏图标/全局快捷键后,这里将改为"隐藏待唤起";
    /// 目前没有再次唤起的入口,所以关闭即退出。
    static func dismiss() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 覆盖层应用:不占 Dock、不切换菜单栏
let delegate = AppDelegate()
app.delegate = delegate
app.run()
