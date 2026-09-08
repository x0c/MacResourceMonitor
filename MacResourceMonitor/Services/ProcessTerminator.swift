import AppKit
import Darwin
import Foundation

nonisolated enum TerminationOutcome: Sendable {
    case ended
    case failed(String)
    case blocked
}

@MainActor
enum ProcessTerminator {
    /// 全应用共用：进程表与网络表可能同时点结束，避免重叠 PID 并发发信号。
    private static var inFlightIdentities: Set<ProcessIdentity> = []

    static func end(_ row: ProcessRow) async -> TerminationOutcome {
        if row.isSystemProtected {
            return .blocked
        }
        if !row.isCurrentUser {
            return .blocked
        }

        let targets = row.memberIdentities
        guard !targets.isEmpty else { return .ended }
        guard targets.allSatisfy({ !inFlightIdentities.contains($0) }) else {
            return .blocked
        }
        for identity in targets {
            inFlightIdentities.insert(identity)
        }
        defer {
            for identity in targets {
                inFlightIdentities.remove(identity)
            }
        }

        switch row.kind {
        case .desktopApp, .chatgpt:
            await endApplication(row, targets: targets)
        case .cursorAgent, .pi, .corral, .namedTool, .other:
            await endInterpreter(targets)
        }

        try? await Task.sleep(for: .milliseconds(200))
        let still = targets.filter(isSameProcess)
        if still.isEmpty {
            return .ended
        }
        return .failed(String(localized: "table.end.failed"))
    }

    private static func endApplication(_ row: ProcessRow, targets: [ProcessIdentity]) async {
        var apps: [NSRunningApplication] = []
        if let bundlePath = row.bundlePath {
            let url = URL(fileURLWithPath: bundlePath)
            apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL == url }
        }
        if apps.isEmpty {
            apps = targets.compactMap { identity in
                guard isSameProcess(identity) else { return nil }
                return NSRunningApplication(processIdentifier: identity.pid)
            }
        }
        for app in apps {
            _ = app.terminate()
        }
        try? await Task.sleep(for: .milliseconds(700))
        for app in apps where !app.isTerminated {
            _ = app.forceTerminate()
        }
        await endInterpreter(targets)
    }

    private static func endInterpreter(_ identities: [ProcessIdentity]) async {
        for identity in identities where shouldSignal(identity) {
            kill(identity.pid, SIGTERM)
        }
        try? await Task.sleep(for: .milliseconds(500))
        for identity in identities where shouldSignal(identity) {
            kill(identity.pid, SIGKILL)
        }
    }

    /// 仍是当初那只进程，且不是系统保护目标，才允许发信号。
    private static func shouldSignal(_ identity: ProcessIdentity) -> Bool {
        guard isSameProcess(identity) else { return false }
        guard let path = path(for: identity.pid) else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return !DisplayClassifier.isProtected(name: name, path: path, pid: identity.pid)
    }

    private static func isSameProcess(_ identity: ProcessIdentity) -> Bool {
        guard kill(identity.pid, 0) == 0 else { return false }
        return startTime(for: identity.pid) == identity.startTime
    }

    private static func startTime(for pid: pid_t) -> TimeInterval {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return 0
        }
        return TimeInterval(info.kp_proc.p_starttime.tv_sec)
            + TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000
    }

    private static func path(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
