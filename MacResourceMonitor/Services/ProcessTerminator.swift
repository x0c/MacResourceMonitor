import Darwin
import Foundation

nonisolated enum TerminationOutcome: Sendable {
    case ended
    case failed(String)
    case blocked
}

nonisolated enum ProcessTerminationSelection {
    static func bulkCandidates(from rows: [ProcessRow], excludingPID: pid_t) -> [ProcessRow] {
        var seenRowIDs: Set<String> = []
        return rows.filter { row in
            row.canEnd
                && !row.memberPIDs.contains(excludingPID)
                && seenRowIDs.insert(row.id).inserted
        }
    }
}

@MainActor
enum ProcessTerminator {
    /// 全应用共用：进程表与网络表可能同时点结束，避免重叠 PID 并发发信号。
    private static var inFlightIdentities: Set<ProcessIdentity> = []

    static func end(_ row: ProcessRow) async -> TerminationOutcome {
        guard row.canEnd else { return .blocked }
        return await forceEnd(row.memberIdentities)
    }

    static func endAll(_ rows: [ProcessRow]) async -> TerminationOutcome {
        let candidates = ProcessTerminationSelection.bulkCandidates(
            from: rows,
            excludingPID: getpid()
        )
        let targets = Array(Set(candidates.flatMap(\.memberIdentities)))
        return await forceEnd(targets)
    }

    private static func forceEnd(_ targets: [ProcessIdentity]) async -> TerminationOutcome {
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

        for identity in targets where shouldSignal(identity) {
            _ = kill(identity.pid, SIGKILL)
        }

        try? await Task.sleep(for: .milliseconds(200))
        let still = targets.filter(isSameProcess)
        if still.isEmpty {
            return .ended
        }
        return .failed(String(localized: "table.end.failed"))
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
