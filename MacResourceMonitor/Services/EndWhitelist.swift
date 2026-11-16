import Foundation
import Observation

/// 白名单：用户不想被结束的行。存显示名 + 包路径（有则更准），匹配时包路径优先、显示名兜底。
/// 包路径保证桌面应用精确；显示名保证解释器行（pi / Corral / 工具 hint）版本升级、路径变化后仍然保护。
/// 图标只做展示用，不参与匹配：iconPath / executablePath 丢了也能照常保护。
/// 宁可多保护（fail-closed），不漏杀。
nonisolated struct WhitelistedApp: Codable, Hashable, Sendable {
    var displayName: String
    var bundlePath: String?
    var kindRaw: String?
    var iconPath: String?
    var executablePath: String?

    init(
        displayName: String,
        bundlePath: String? = nil,
        kindRaw: String? = nil,
        iconPath: String? = nil,
        executablePath: String? = nil
    ) {
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.kindRaw = kindRaw
        self.iconPath = iconPath
        self.executablePath = executablePath
    }

    init(row: ProcessRow) {
        self.displayName = row.displayName
        self.bundlePath = row.bundlePath
        self.kindRaw = row.kind.rawValue
        self.iconPath = row.iconPath
        self.executablePath = row.executablePath
    }

    /// 设置窗展示用，和列表行取同一张图；路径失效时回退到通用可执行图标。
    var displayIconPath: String? {
        iconPath ?? bundlePath ?? executablePath
    }

    /// 包路径相同直接命中；否则显示名忽略大小写命中（兜底搬家/改名/解释器路径变化）。
    func matches(row: ProcessRow) -> Bool {
        if let mine = bundlePath, !mine.isEmpty,
           let theirs = row.bundlePath, !theirs.isEmpty,
           mine == theirs {
            return true
        }
        return displayName.lowercased() == row.displayName.lowercased()
    }
}

nonisolated enum EndWhitelist {
    static let defaultsKey = "protection.whitelist.v1"
    static let appDomain = "top.caozc.MacResourceMonitor"

    /// CLI（mrm）没有 bundle，用 suite 读应用同一份偏好；应用内直接用 standard 也同一文件。
    static func appDefaults() -> UserDefaults {
        UserDefaults(suiteName: appDomain) ?? UserDefaults.standard
    }

    static func load(from defaults: UserDefaults = .standard) -> [WhitelistedApp] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        guard let entries = try? JSONDecoder().decode([WhitelistedApp].self, from: data) else { return [] }
        return entries.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func save(_ entries: [WhitelistedApp], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func isWhitelisted(_ row: ProcessRow, entries: [WhitelistedApp]) -> Bool {
        entries.contains { $0.matches(row: row) }
    }
}

/// 应用内唯一可观察源；右键与设置窗都走这里，批量结束/单行结束/doom 统一查它。
@MainActor
@Observable
final class WhitelistStore {
    static let shared = WhitelistStore()

    var entries: [WhitelistedApp] = [] {
        didSet {
            EndWhitelist.save(entries, to: defaults)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = EndWhitelist.load(from: defaults)
    }

    func isWhitelisted(_ row: ProcessRow) -> Bool {
        EndWhitelist.isWhitelisted(row, entries: entries)
    }

    func contains(_ row: ProcessRow) -> Bool {
        isWhitelisted(row)
    }

    func add(_ row: ProcessRow) {
        let entry = WhitelistedApp(row: row)
        guard !entries.contains(entry) else { return }
        // 同名即同一保护对象：显示名相同不再重复加。
        guard !entries.contains(where: { $0.displayName.lowercased() == entry.displayName.lowercased() }) else { return }
        entries.append(entry)
        entries.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func remove(_ row: ProcessRow) {
        entries.removeAll { $0.matches(row: row) }
    }

    func remove(entry: WhitelistedApp) {
        entries.removeAll { $0 == entry }
    }

    func toggle(_ row: ProcessRow) {
        if isWhitelisted(row) {
            remove(row)
        } else {
            add(row)
        }
    }

    func reload() {
        entries = EndWhitelist.load(from: defaults)
    }
}
