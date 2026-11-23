import AppKit
import SwiftUI
import CoreBluetooth

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var item: NSStatusItem!
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "appletvremote.gen4", accessibilityDescription: "RemoteVibe")
        if item.button?.image == nil { item.button?.title = "RV" }
        item.button?.toolTip = "RemoteVibe"
        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reconnect = NSMenuItem(title: "重新连接遥控器", action: #selector(reconnectRemote), keyEquivalent: "")
        reconnect.target = self
        menu.addItem(reconnect)
        let setup = NSMenuItem(title: "重新运行配置向导", action: #selector(restartSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        showSettings()
        if model.settings.onboardingComplete && model.settings.peripheralID != nil && CBManager.authorization == .allowedAlways { model.connect() }
    }

    @objc private func reconnectRemote() { model.connect() }
    @objc private func restartSetup() { model.restartSetup(); showSettings() }
    @objc func showSettings() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 772), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "RemoteVibe"
            window.contentView = NSHostingView(rootView: RemoteVibeRootView(model: model))
            window.contentMinSize = NSSize(width: 980, height: 732)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

@main
struct RemoteVibeApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
