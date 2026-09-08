import Foundation
import Observation

nonisolated enum AppPreferences {
    static let launchAtLoginKey = "general.launchAtLogin"
    static let launchAtLoginDefault = false

    /// 冻结开关：开 = 名单尽量不动；默认关。旧键 `panel.refreshEnabled` 语义相反，读取时做一次迁移。
    static let listFrozenKey = "panel.listFrozen"
    static let listFrozenDefault = false
    static let networkListFrozenKey = "panel.networkListFrozen"
    static let networkListFrozenDefault = false
    static let legacyRefreshEnabledKey = "panel.refreshEnabled"
    static let legacyNetworkRefreshEnabledKey = "panel.networkRefreshEnabled"

    static let showNetworkSpeedKey = "menuBar.showNetworkSpeed"
    static let showNetworkSpeedDefault = true

    static let refreshInterval: TimeInterval = 1.5
    /// 网络列表直接采用 nettop 的一秒差分，节奏必须与菜单栏读数一致。
    static let networkRefreshInterval: TimeInterval = 1

    /// 常显滚动条后名字列仍够 Google Chrome / Activity Monitor；禁止为包名再加宽。
    static let compactSize = CGSize(width: 368, height: 360)
    static let compactCornerRadius: CGFloat = 16
    static let metricColumnWidth: CGFloat = 66
    static let endColumnWidth: CGFloat = 22

    /// 读冻结偏好；若仍有旧「刷新」键，取其反义并写入新键。
    /// 旧键优先处理，避免注册域里的新键默认值挡住迁移。
    static func readListFrozen(
        defaults: UserDefaults = .standard,
        key: String,
        legacyKey: String,
        defaultValue: Bool
    ) -> Bool {
        if defaults.object(forKey: legacyKey) != nil {
            let frozen = !defaults.bool(forKey: legacyKey)
            defaults.set(frozen, forKey: key)
            defaults.removeObject(forKey: legacyKey)
            return frozen
        }
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return defaultValue
    }
}

/// 菜单栏展示偏好集中在这里，避免菜单状态和绘制状态各存一份。
@MainActor
@Observable
final class MenuBarDisplayPreferences {
    static let shared = MenuBarDisplayPreferences()

    var showsNetworkSpeed: Bool {
        didSet {
            defaults.set(showsNetworkSpeed, forKey: AppPreferences.showNetworkSpeedKey)
            onChange?()
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsNetworkSpeed = defaults.object(forKey: AppPreferences.showNetworkSpeedKey) as? Bool
            ?? AppPreferences.showNetworkSpeedDefault
    }
}
