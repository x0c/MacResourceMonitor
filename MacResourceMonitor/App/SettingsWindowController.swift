import AppKit
import MacKitLifecycle
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private static let frameAutosaveName = "MacResourceMonitor.Recovery"

    private var window: NSWindow?
    private let activationSession = AccessoryActivationSession()

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "settings.title")
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // 先落到屏幕中央，再按已记住的位置恢复；键不存在时不会钉在角落。
            window.setFrameAutosaveName(Self.frameAutosaveName)
            self.window = window
        }

        activationSession.beginIfAccessory()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        activationSession.endIfNeeded()
    }
}
