import Foundation

nonisolated struct ProcessIdentity: Hashable, Sendable {
    var pid: pid_t
    var startTime: TimeInterval
}

nonisolated struct RawProcess: Sendable, Hashable {
    var identity: ProcessIdentity
    var ppid: pid_t
    var uid: uid_t
    var path: String
    var arguments: [String]
    var responsiblePID: pid_t
    var cpuPercent: Double
    var memoryBytes: UInt64

    var pid: pid_t { identity.pid }

    var executableName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

nonisolated enum RowKind: String, Sendable {
    case desktopApp
    case chatgpt
    case cursorAgent
    case pi
    case corral
    case namedTool
    case other
}

nonisolated struct ProcessRow: Identifiable, Sendable, Hashable {
    var id: String
    var displayName: String
    var bundlePath: String?
    var iconPath: String?
    /// 结束与存活检测必须用 PID+启动时刻，避免 SIGTERM 等待期间 PID 复用误杀。
    var memberIdentities: [ProcessIdentity]
    var cpuPercent: Double
    var memoryPercent: Double
    var kind: RowKind
    var isCurrentUser: Bool
    var isSystemProtected: Bool

    var memberPIDs: [pid_t] { memberIdentities.map(\.pid) }
}
