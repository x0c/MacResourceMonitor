import AppKit
import MacKitCore

enum StatusItemPanelTarget: Equatable {
    case process
    case networkUpload
    case networkDownload
}

/// 系统状态栏会从右向左接纳后来加入的项目；固定创建顺序，保证圆环在左、网速在右。
extension StatusItemPanelTarget {
    static let statusItemCreationOrder: [StatusItemPanelTarget] = [.networkDownload, .process]
}

/// 本地状态项：菜单栏图标是动态双环，不能换成静态图。左右键分发仍在这里，左键永不弹菜单。
/// 图标即主入口，禁止隐藏；圆环始终可见，网速项仅受「显示网速」偏好控制。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var ringStatusItem: NSStatusItem!
    private var networkStatusItem: NSStatusItem!
    private let menu: NSMenu
    private var activeStatusItem: NSStatusItem?
    private let onOpenPanel: (StatusItemPanelTarget) -> Void
    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onQuit: () -> Void
    private let launchAtLogin = LaunchAtLoginManager.shared
    private let displayPreferences = MenuBarDisplayPreferences.shared
    private var cpuPercent = 0.0
    private var memoryPercent = 0.0
    private var uploadBytesPerSecond: Double?
    private var downloadBytesPerSecond: Double?

    private lazy var launchAtLoginItem = NSMenuItem(
        title: String(localized: "menu.launchAtLogin"),
        action: #selector(toggleLaunchAtLogin(_:)),
        keyEquivalent: ""
    )
    private lazy var openLoginItemsItem = NSMenuItem(
        title: String(localized: "menu.openLoginItems"),
        action: #selector(openLoginItems(_:)),
        keyEquivalent: ""
    )
    private lazy var showNetworkSpeedItem = NSMenuItem(
        title: String(localized: "menu.showNetworkSpeed"),
        action: #selector(toggleNetworkSpeed(_:)),
        keyEquivalent: ""
    )
    private lazy var openMainWindowItem = NSMenuItem(
        title: String(localized: "menu.openMainWindow"),
        action: #selector(openMainWindow(_:)),
        keyEquivalent: ""
    )
    private lazy var settingsItem = NSMenuItem(
        title: String(localized: "menu.settings"),
        action: #selector(openSettings(_:)),
        keyEquivalent: ","
    )
    private lazy var checkForUpdatesItem = NSMenuItem(
        title: String(localized: "menu.checkForUpdates"),
        action: #selector(checkForUpdates(_:)),
        keyEquivalent: ""
    )
    private lazy var quitItem = NSMenuItem(
        title: String(localized: "menu.quit"),
        action: #selector(quit(_:)),
        keyEquivalent: "q"
    )

    init(
        onOpenPanel: @escaping (StatusItemPanelTarget) -> Void,
        onOpenMainWindow: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenPanel = onOpenPanel
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onQuit = onQuit
        menu = NSMenu()
        super.init()
        configureMenu()
        rebuildStatusItems()
        displayPreferences.onChange = { [weak self] in
            self?.rebuildStatusItems()
        }
    }

    func buttonScreenFrame() -> NSRect? {
        guard let item = activeStatusItem ?? ringStatusItem,
              let button = item.button,
              let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard PanelPlacement.isMenuBarAnchor(frame, screens: NSScreen.screens.map(\.frame)) else {
            return nil
        }
        return frame
    }

    private func rebuildStatusItems() {
        if let ringStatusItem {
            NSStatusBar.system.removeStatusItem(ringStatusItem)
        }
        if let networkStatusItem {
            NSStatusBar.system.removeStatusItem(networkStatusItem)
        }
        activeStatusItem = nil

        for target in StatusItemPanelTarget.statusItemCreationOrder {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            configureButton(item.button, target: target)
            switch target {
            case .process:
                ringStatusItem = item
            case .networkUpload, .networkDownload:
                networkStatusItem = item
            }
        }

        ringStatusItem.length = MenuBarIconRenderer.pointSize
        networkStatusItem.length = MenuBarIconRenderer.networkWidth
        renderStatusItem()
        applyIconVisibility()
    }

    private func configureButton(_ button: NSStatusBarButton?, target: StatusItemPanelTarget) {
        guard let button else { return }
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        // 保持 nil，让系统按菜单栏明暗给模板图上色；禁止手写黑/白。
        button.contentTintColor = nil
        button.setAccessibilityLabel(String(localized: "status.item.accessibility"))
        button.target = self
        // 状态栏按钮会吞掉右键；NSClickGestureRecognizer 的 buttonMask=右键经常收不到。
        // 必须用 sendAction 同时接收左右键抬起，再按当前事件分流。
        button.action = target == .process ? #selector(handleRingClick(_:)) : #selector(handleNetworkClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func updateMetrics(cpuPercent: Double, memoryPercent: Double) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        renderStatusItem()
    }

    func updateNetworkSpeed(uploadBytesPerSecond: Double?, downloadBytesPerSecond: Double?) {
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        renderStatusItem()
    }

    private func applyIconVisibility() {
        ringStatusItem.isVisible = true
        networkStatusItem.isVisible = displayPreferences.showsNetworkSpeed
    }

    private func configureMenu() {
        for item in [
            openMainWindowItem,
            launchAtLoginItem,
            openLoginItemsItem,
            showNetworkSpeedItem,
            settingsItem,
            checkForUpdatesItem,
            quitItem
        ] {
            item.target = self
        }
        menu.delegate = self
        menu.items = [
            openMainWindowItem,
            launchAtLoginItem,
            openLoginItemsItem,
            showNetworkSpeedItem,
            settingsItem,
            checkForUpdatesItem,
            .separator(),
            quitItem
        ]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLogin.refresh()
        launchAtLoginItem.state = menuState(for: launchAtLogin.status)
        openLoginItemsItem.isHidden = !launchAtLogin.requiresApproval
        showNetworkSpeedItem.state = displayPreferences.showsNetworkSpeed ? .on : .off
    }

    @objc
    private func handleRingClick(_ sender: Any?) {
        handleStatusItemClick(statusItem: ringStatusItem) {
            self.onOpenPanel(.process)
        }
    }

    @objc
    private func handleNetworkClick(_ sender: Any?) {
        handleStatusItemClick(statusItem: networkStatusItem) {
            self.onOpenPanel(.networkDownload)
        }
    }

    private func handleStatusItemClick(statusItem: NSStatusItem, openPanel: () -> Void) {
        activeStatusItem = statusItem
        guard let event = NSApp.currentEvent else {
            openPanel()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(on: statusItem)
        } else {
            openPanel()
        }
    }

    /// 临时挂上菜单再 performClick，避免常挂劫持左键；勿用不可靠的手势或已弃用的 popUpMenu。
    private func showContextMenu(on statusItem: NSStatusItem) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc
    private func toggleLaunchAtLogin(_ sender: Any?) {
        launchAtLogin.refresh()
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
    }

    @objc
    private func openLoginItems(_ sender: Any?) {
        launchAtLogin.openSystemSettings()
    }

    @objc
    private func toggleNetworkSpeed(_ sender: Any?) {
        displayPreferences.showsNetworkSpeed.toggle()
    }

    @objc
    private func openMainWindow(_ sender: Any?) {
        onOpenMainWindow()
    }

    @objc
    private func openSettings(_ sender: Any?) {
        onOpenSettings()
    }

    @objc
    private func checkForUpdates(_ sender: Any?) {
        onCheckForUpdates()
    }

    @objc
    private func quit(_ sender: Any?) {
        onQuit()
    }

    private func menuState(for status: LaunchAtLoginStatus) -> NSControl.StateValue {
        switch status.menuTriState {
        case .on: return .on
        case .off: return .off
        case .mixed: return .mixed
        }
    }

    private func renderStatusItem() {
        applyTemplateImage(
            MenuBarIconRenderer.image(
                cpuPercent: cpuPercent,
                memoryPercent: memoryPercent
            ),
            to: ringStatusItem
        )
        applyTemplateImage(
            MenuBarIconRenderer.networkImage(
                uploadBytesPerSecond: uploadBytesPerSecond,
                downloadBytesPerSecond: downloadBytesPerSecond
            ),
            to: networkStatusItem
        )
        networkStatusItem.isVisible = displayPreferences.showsNetworkSpeed
    }

    private func applyTemplateImage(_ image: NSImage, to statusItem: NSStatusItem) {
        image.isTemplate = true
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil
        button.image = image
        // 赋值后再钉一次，避免按钮拷贝丢模板标记。
        button.image?.isTemplate = true
    }
}
