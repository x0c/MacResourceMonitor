import Darwin
import Foundation

// MARK: - Doom data model (JSON)

struct DoomRowDTO: Encodable {
    var display_name: String
    var kind: String
    var pids: [Int32]
    var cpu_percent: Double
    var memory_percent: Double
}

struct DoomSkippedDTO: Encodable {
    var display_name: String
    var kind: String
    var pids: [Int32]
    /// Stable English enum for programs.
    var reason: String
    /// Localized copy for humans.
    var reason_tag: String
}

struct DoomCountsDTO: Encodable {
    var scanned: Int
    var candidates: Int
    var killed: Int
    var failed: Int
    var skipped: Int
}

struct DoomDataDTO: Encodable {
    var action: String = "doom"
    var dry_run: Bool
    /// Present on real runs; equals candidates on dry-run.
    var killed: [DoomRowDTO]
    var failed: [DoomRowDTO]
    /// Dry-run plan (same shape as killed on a real run).
    var would_kill: [DoomRowDTO]
    var skipped: [DoomSkippedDTO]
    var counts: DoomCountsDTO
    /// Judgment-affecting tip for agents (also rendered in human text).
    var note: String?
}

// MARK: - Snapshot helpers

struct DoomSnapshot {
    var rows: [ProcessRow]
    var rawCount: Int
    var physicalMemory: UInt64
}

func collectSnapshot() async -> DoomSnapshot {
    let sampler = ProcessSampler(reapOrphans: false)
    // First pass warms CPU deltas; second pass carries real percentages.
    // Same two-tap rhythm as the menu-bar app (350ms apart).
    _ = await sampler.snapshot()
    try? await Task.sleep(for: .milliseconds(350))
    let second = await sampler.snapshot()
    let memory = await sampler.memoryBytes
    let rows = DisplayClassifier.rows(
        from: second.records,
        currentUID: getuid(),
        physicalMemory: memory
    )
    return DoomSnapshot(rows: rows, rawCount: second.records.count, physicalMemory: memory)
}

// MARK: - Process identity helpers (mirror ProcessTerminator safety)

func ppid(of pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
    return info.kp_eproc.e_ppid
}

func ancestorPIDs() -> Set<pid_t> {
    var out: Set<pid_t> = []
    var current = getppid()
    var hops = 0
    while current > 1, hops < 16 {
        out.insert(current)
        guard let parent = ppid(of: current), parent != current else { break }
        current = parent
        hops += 1
    }
    return out
}

func startTime(for pid: pid_t) -> TimeInterval {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
    return TimeInterval(info.kp_proc.p_starttime.tv_sec)
        + TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000
}

func executablePath(for pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

func isSameProcess(_ identity: ProcessIdentity) -> Bool {
    guard kill(identity.pid, 0) == 0 else { return false }
    return startTime(for: identity.pid) == identity.startTime
}

func shouldSignal(_ identity: ProcessIdentity) -> Bool {
    guard isSameProcess(identity) else { return false }
    guard let path = executablePath(for: identity.pid) else { return false }
    let name = URL(fileURLWithPath: path).lastPathComponent
    return !DisplayClassifier.isProtected(name: name, path: path, pid: identity.pid)
}

// MARK: - Doom planning

struct DoomPlan {
    var candidates: [ProcessRow]
    var skipped: [(row: ProcessRow, reason: String)]
}

func isMonitorRow(_ row: ProcessRow) -> Bool {
    if let bundle = row.bundlePath, bundle.contains("Mac Resource Monitor.app") { return true }
    if row.displayName == "Mac Resource Monitor" { return true }
    if row.executablePath.contains("Mac Resource Monitor.app/") { return true }
    return false
}

func matchesExclude(_ row: ProcessRow, patterns: [String]) -> Bool {
    guard !patterns.isEmpty else { return false }
    let haystacks = [
        row.displayName.lowercased(),
        row.bundlePath?.lowercased() ?? "",
        row.executablePath.lowercased(),
    ]
    for raw in patterns {
        let needle = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { continue }
        for hay in haystacks where hay.contains(needle) { return true }
    }
    return false
}

/// PIDs that must survive doom unless explicitly opted in: the mrm process,
/// its Unix ancestors (shell chain), and the responsible owners of that chain
/// (e.g. the iTerm2/Terminal GUI that hosts the invoking shell — killing it
/// would destroy the session before results print, even though the GUI pid
/// itself is never a Unix ancestor of mrm).
func callerProtectedPIDs(selfPID: pid_t, ancestors: Set<pid_t>) -> Set<pid_t> {
    var out = ancestors
    out.insert(selfPID)
    for pid in ancestors.union([selfPID]) {
        let responsible = Responsibility.pidResponsible(for: pid)
        if responsible > 1 { out.insert(responsible) }
    }
    return out
}

func planDoom(
    rows: [ProcessRow],
    ancestors: Set<pid_t>,
    selfPID: pid_t,
    excludes: [String],
    includeCaller: Bool,
    includeMonitor: Bool
) -> DoomPlan {
    let callerPIDs = callerProtectedPIDs(selfPID: selfPID, ancestors: ancestors)
    var candidates: [ProcessRow] = []
    var skipped: [(ProcessRow, String)] = []
    for row in rows {
        if !row.canEnd {
            skipped.append((row, row.isCurrentUser ? "protected" : "other_user"))
            continue
        }
        if row.skipsBulkEnd {
            skipped.append((row, "relaunches"))
            continue
        }
        // Any mrm binary (self or a concurrent doom run) is never a target.
        if row.memberPIDs.contains(selfPID) || row.displayName == "mrm"
            || row.executablePath.hasSuffix("/mrm") {
            skipped.append((row, "self"))
            continue
        }
        if !includeCaller, row.memberPIDs.contains(where: { callerPIDs.contains($0) }) {
            skipped.append((row, "caller"))
            continue
        }
        // nettop stream samplers are the monitor's network infrastructure
        // (or an orphan of it). Killing them breaks the menu-bar network table
        // and orphans spin at ~1 core; treat like the monitor itself.
        if !includeMonitor, isMonitorRow(row)
            || NettopStreamSampler.isSamplerExecutable(row.executablePath) {
            skipped.append((row, "monitor"))
            continue
        }
        if matchesExclude(row, patterns: excludes) {
            skipped.append((row, "excluded"))
            continue
        }
        candidates.append(row)
    }
    // Most expensive first, same order users see in the menu-bar table.
    candidates.sort {
        if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
        return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    return DoomPlan(candidates: candidates, skipped: skipped)
}

func reasonTag(_ reason: String) -> String {
    switch reason {
    case "protected": return MRMLang.pick("system, kept", "系统进程，保留")
    case "other_user": return MRMLang.pick("other user, kept", "其他用户，保留")
    case "self": return MRMLang.pick("mrm itself, kept", "mrm 自身，保留")
    case "caller": return MRMLang.pick("your terminal chain, kept", "当前终端链，保留")
    case "monitor": return MRMLang.pick("monitor, kept", "监控自身，保留")
    case "excluded": return MRMLang.pick("excluded by flag, kept", "按参数排除，保留")
    case "relaunches": return MRMLang.pick("relaunched by macOS, kept", "系统会自动重开，保留")
    default: return reason
    }
}

// MARK: - Doom execution

struct DoomResult {
    var killed: [ProcessRow]
    var failed: [ProcessRow]
}

func executeDoom(candidates: [ProcessRow]) async -> DoomResult {
    let targets = Array(Set(candidates.flatMap(\.memberIdentities)))
    guard !targets.isEmpty else { return DoomResult(killed: [], failed: []) }

    for identity in targets where shouldSignal(identity) {
        _ = kill(identity.pid, SIGKILL)
    }
    // Give the kernel a beat to reap, then verify terminal state by re-reading
    // liveness (not by trusting the kill return value).
    try? await Task.sleep(for: .milliseconds(250))

    let still = Set(targets.filter(isSameProcess))
    if still.isEmpty {
        return DoomResult(killed: candidates, failed: [])
    }
    var killed: [ProcessRow] = []
    var failed: [ProcessRow] = []
    for row in candidates {
        let alive = row.memberIdentities.contains(where: { still.contains($0) })
        if alive { failed.append(row) } else { killed.append(row) }
    }
    return DoomResult(killed: killed, failed: failed)
}

// MARK: - DTO mapping

func dto(_ row: ProcessRow) -> DoomRowDTO {
    DoomRowDTO(
        display_name: row.displayName,
        kind: row.kind.rawValue,
        pids: row.memberPIDs.map { Int32($0) },
        cpu_percent: (row.cpuPercent * 10).rounded() / 10,
        memory_percent: (row.memoryPercent * 10).rounded() / 10
    )
}
