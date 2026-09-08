import Foundation
import MacKitCore
import MacKitLaunchAtLogin
import Observation

@MainActor
@Observable
final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let service = LaunchAtLoginService()
    private(set) var status: LaunchAtLoginStatus
    private(set) var lastErrorMessage: String?

    private init() {
        status = service.status
    }

    /// 只有系统真正会在登录时拉起才算开。待批准不能算已启用。
    var isEnabled: Bool { status.isEffectivelyEnabled }

    var requiresApproval: Bool { status == .needsApproval }

    func setEnabled(_ enabled: Bool) {
        if requiresApproval, enabled {
            service.openSystemSettings()
            refresh()
            return
        }
        switch service.setEnabled(enabled) {
        case .success(let newStatus):
            status = newStatus
            lastErrorMessage = nil
        case .failure:
            refresh()
            lastErrorMessage = String(localized: "settings.launchAtLogin.failed")
        }
    }

    func refresh() {
        service.refresh()
        status = service.status
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
