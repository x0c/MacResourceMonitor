import AppKit
import MacKitCore
import MacKitLifecycle
import MacKitUpdater
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static weak var shared: AppDelegate?
    let listModel = ProcessListModel()
    private lazy var networkListModel = NetworkListModel { [weak self] in
        self?.listModel.latestRows ?? []
    }
    private let networkSpeedMonitor = NetworkSpeedMonitor()
    private var statusItemController: StatusItemController?
    private var compactPanel: CompactPanel?
    private let appUpdater = SparkleUpdateChecker()
    private let terminationGuard = TerminationGuard()
    private var commaMonitor: Any?
    /// 后台就绪时刻；菜单栏即主入口的二次启动防呆用。
    private var readyAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // 图标即主入口：清掉历史显隐偏好，启动强制图标可见。
        UserDefaults.standard.removeObject(forKey: "menuBar.iconVisible")
        terminationGuard.isUpdateSessionInProgress = { [weak self] in
            self?.appUpdater.isSessionInProgress ?? false
        }

        let panel = CompactPanel(processModel: listModel, networkModel: networkListModel)
        compactPanel = panel

        statusItemController = StatusItemController(
            onOpenPanel: { [weak self] in self?.toggleCompactPanel(for: $0) },
            onOpenMainWindow: { [weak self] in self?.showRecoveryWindow() },
            onOpenSettings: { [weak self] in self?.showSettings() },
            onCheckForUpdates: { [weak self] in self?.checkForUpdates() },
            onQuit: { [weak self] in self?.requestTermination() }
        )
        listModel.setMetricsObserver { [weak statusItemController] cpuPercent, memoryPercent in
            statusItemController?.updateMetrics(
                cpuPercent: cpuPercent,
                memoryPercent: memoryPercent
            )
        }
        networkSpeedMonitor.setObserver { [weak statusItemController] uploadBytesPerSecond, downloadBytesPerSecond in
            statusItemController?.updateNetworkSpeed(
                uploadBytesPerSecond: uploadBytesPerSecond,
                downloadBytesPerSecond: downloadBytesPerSecond
            )
        }
        networkSpeedMonitor.start()
        panel.additionalKeptFrames = { [weak statusItemController] in
            statusItemController?.buttonScreenFrame().map { [$0] } ?? []
        }
        panel.onVisibilityChange = { [weak self] content, visible in
            switch content {
            case .process:
                self?.listModel.setPanelVisible(visible)
            case .network:
                self?.networkListModel.setPanelVisible(visible)
            }
        }

        commaMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            if command, event.charactersIgnoringModifiers == "," {
                SettingsWindowController.shared.show()
                return nil
            }
            return event
        }

        // 图标始终可见；登录项拉起时仍传入判定，禁止自动弹设置窗。
        let isLoginLaunch = LoginLaunchDetector.isLaunchedAsLoginItem
        readyAt = Date()
        if MenuBarReopenPolicy.shouldShowRecoveryWindow(
            iconVisible: true,
            isLoginLaunch: isLoginLaunch
        ) {
            showRecoveryWindow()
        } else if !isLoginLaunch, CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showPanelBelowStatusItem(content: .process, attempt: 0)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationGuard.shouldTerminate() ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 菜单栏即主入口：时间窗内二次打开须出设置窗（含检查更新等对等入口），与图标可见无关。
        if MenuBarReopenPolicy.presentation(
            iconVisible: true,
            isReopenOrLaunch: true,
            isLoginLaunch: false,
            menubarIsPrimaryEntry: true,
            secondsSinceReady: Date().timeIntervalSince(readyAt)
        ) == .showRecoveryWindow {
            showRecoveryWindow()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let commaMonitor {
            NSEvent.removeMonitor(commaMonitor)
        }
        networkListModel.stopSamplingNow()
        networkSpeedMonitor.stop()
        NettopStreamSampler.reapOrphanedSamplers()
    }

    func requestTermination() {
        terminationGuard.requestTermination()
    }

    func checkForUpdates() {
        appUpdater.checkForUpdates(nil)
    }

    func showSettings() {
        compactPanel?.hidePanel()
        SettingsWindowController.shared.show()
    }

    func showRecoveryWindow() {
        showSettings()
    }

    private func toggleCompactPanel(for target: StatusItemPanelTarget) {
        guard let panel = compactPanel else { return }
        let content: CompactPanelContent
        switch target {
        case .process:
            content = .process
        case .networkUpload, .networkDownload:
            networkListModel.sortColumn = .download
            content = .network
        }
        if panel.isVisible, panel.currentContent == content {
            panel.hidePanel()
        } else if panel.isVisible {
            panel.switchContent(to: content)
        } else {
            showPanelBelowStatusItem(content: content, attempt: 0)
        }
    }

    private func showPanelBelowStatusItem(content: CompactPanelContent, attempt: Int) {
        guard let panel = compactPanel else { return }
        let frame = statusItemController?.buttonScreenFrame()
        let screens = NSScreen.screens.map(\.frame)
        if let frame, PanelPlacement.isMenuBarAnchor(frame, screens: screens) {
            panel.show(anchor: frame, content: content)
            return
        }
        if attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.showPanelBelowStatusItem(content: content, attempt: attempt + 1)
            }
            return
        }
        panel.show(anchor: nil, content: content)
    }
}
