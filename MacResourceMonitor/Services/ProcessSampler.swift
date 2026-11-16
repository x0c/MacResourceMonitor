import Darwin
import Foundation

nonisolated private let procPIDPathMax: UInt32 = 4096

nonisolated private struct ProcTaskInfo {
    var pti_virtual_size: UInt64 = 0
    var pti_resident_size: UInt64 = 0
    var pti_total_user: UInt64 = 0
    var pti_total_system: UInt64 = 0
    var pti_threads_user: UInt64 = 0
    var pti_threads_system: UInt64 = 0
    var pti_policy: Int32 = 0
    var pti_faults: Int32 = 0
    var pti_pageins: Int32 = 0
    var pti_cow_faults: Int32 = 0
    var pti_messages_sent: Int32 = 0
    var pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32 = 0
    var pti_syscalls_unix: Int32 = 0
    var pti_csw: Int32 = 0
    var pti_threadnum: Int32 = 0
    var pti_numrunning: Int32 = 0
    var pti_priority: Int32 = 0
}

actor ProcessSampler {
    private struct CPUSample {
        var totalTicks: UInt64
        var systemTicks: UInt64
        var wall: TimeInterval
    }

    private struct ForeignCPUSample {
        var seconds: Double
        var wall: TimeInterval
    }

    private struct BSDProcessMeta {
        let pid: pid_t
        let ppid: pid_t
        let uid: uid_t
        let startTime: TimeInterval
    }

    private struct SampledCPU {
        let proc: BSDProcessMeta
        let identity: ProcessIdentity
        let canQueryTask: Bool
        let cpuPercent: Double
    }

    private static let hostSmoothingWindow = 3

    private var previousCPU: [ProcessIdentity: CPUSample] = [:]
    /// Cross-UID baselines from `/bin/ps`; only advanced while a table is open.
    private var previousForeignCPU: [ProcessIdentity: ForeignCPUSample] = [:]
    /// Short rolling window (~2–3 s) for header/ring stability; last element gives the
    /// exact 1-step delta aligned with per-process ticks for `kernel_task` bounding.
    private var hostLoadHistory: [SystemCPULoad] = []
    private var pathCache: [ProcessIdentity: String] = [:]
    private let arguments = ArgumentCache()
    private let logicalCores: Int
    private let physicalMemory: UInt64
    private let currentUID: uid_t

    init(reapOrphans: Bool = true) {
        self.logicalCores = max(ProcessInfo.processInfo.processorCount, 1)
        self.physicalMemory = Self.readPhysicalMemory()
        self.currentUID = getuid()
        // CLI (mrm doom) must not reap: its own PID differs from the menu-bar app,
        // so the app's live nettop child would look "foreign" and be killed.
        if reapOrphans {
            DispatchQueue.global(qos: .utility).async {
                NettopStreamSampler.reapOrphanedSamplers()
            }
        }
    }

    var memoryBytes: UInt64 { physicalMemory }

    var memoryUsagePercent: Double? {
        Self.readMemoryUsagePercent(physicalMemory: physicalMemory)
    }

    /// `includeForeignCPU` is true only while the CPU / memory table is visible: the
    /// network table needs process identities but never displays cross-UID CPU, and a
    /// per-second `/bin/ps` child is exactly what the hidden-panel rule forbids.
    func snapshot(collectDetails: Bool = true, includeForeignCPU: Bool = true) async -> (
        records: [RawProcess], cpuSampleReady: Bool, totalCPUPercent: Double
    ) {
        let hadForeignBaseline = !previousForeignCPU.isEmpty
        // Cross-UID CPU needs /bin/ps, and only an open table may pay for it.
        // Run ps before the synchronous host + task-info pass so host ticks and
        // same-UID deltas stay tightly aligned with zero intervening await hops.
        let wantsForeignCPU = collectDetails && includeForeignCPU
        let psStart = ProcessInfo.processInfo.systemUptime
        let foreign = wantsForeignCPU ? await ForeignProcessCPU.read() : nil
        let psMid = (psStart + ProcessInfo.processInfo.systemUptime) / 2
        if !wantsForeignCPU {
            // Closing the table drops the baselines, so reopening never averages the
            // whole closed period into one misleading tick. A failed ps run keeps them:
            // the next successful run then still spans the whole interval.
            previousForeignCPU.removeAll()
        }

        let now = ProcessInfo.processInfo.systemUptime
        let unixNow = Date().timeIntervalSince1970
        let hostLoad = SystemCPULoad.read()
        let bsdProcesses = Self.allBSDProcesses()

        let instantBreakdown = hostLoad.flatMap { current in
            hostLoadHistory.last.flatMap { current.breakdown(since: $0) }
        }
        let smoothedHostPercent = hostLoad.flatMap { current in
            hostLoadHistory.first.flatMap { current.percent(since: $0) }
        }

        var sampled: [SampledCPU] = []
        sampled.reserveCapacity(bsdProcesses.count)
        var live: Set<ProcessIdentity> = []
        live.reserveCapacity(bsdProcesses.count)
        var attributedCPUPercent = 0.0
        var ownedSystemPercent = 0.0

        for proc in bsdProcesses {
            let pid = proc.pid
            guard pid > 0 else { continue }
            let identity = ProcessIdentity(pid: pid, startTime: proc.startTime)
            // XNU rejects PROC_PIDTASKINFO and proc_pid_rusage with EPERM for non-owned UIDs unless root.
            let canQueryTask = currentUID == 0 || proc.uid == currentUID
            let cpu: Double
            if canQueryTask {
                let owned = ownedCPUPercent(pid: pid, identity: identity, now: now)
                cpu = owned.total
                ownedSystemPercent += owned.system
            } else {
                cpu = foreignCPUPercent(proc: proc, identity: identity, wallNow: psMid, foreign: foreign)
            }
            live.insert(identity)
            attributedCPUPercent += cpu
            if collectDetails {
                sampled.append(
                    SampledCPU(proc: proc, identity: identity, canQueryTask: canQueryTask, cpuPercent: cpu)
                )
            }
        }

        var records: [RawProcess] = []
        if collectDetails {
            records.reserveCapacity(sampled.count + 1)
            for item in sampled {
                guard let record = await buildRecord(item, unixNow: unixNow) else { continue }
                records.append(record)
            }
        }

        previousCPU = previousCPU.filter { live.contains($0.key) }
        previousForeignCPU = previousForeignCPU.filter { live.contains($0.key) }
        pathCache = pathCache.filter { live.contains($0.key) }
        await arguments.prune(keeping: live)
        if let hostLoad {
            hostLoadHistory.append(hostLoad)
            if hostLoadHistory.count > Self.hostSmoothingWindow {
                hostLoadHistory.removeFirst(hostLoadHistory.count - Self.hostSmoothingWindow)
            }
        }

        // ps skips PID 0, so kernel_task is inferred from the 1-step host gap, bounded
        // by unattributed kernel-space ticks so exited user-space builds do not masquerade
        // as kernel_task. Require a cross-UID baseline so opening the panel stays calm.
        if collectDetails,
           hadForeignBaseline,
           foreign != nil,
           let kernelCPU = Self.kernelTaskCPUPercent(
               instantHost: instantBreakdown,
               attributedTotal: attributedCPUPercent,
               ownedSystem: ownedSystemPercent
           ) {
            records.append(Self.kernelTaskRecord(cpuPercent: kernelCPU))
        }

        let totalCPUPercent = smoothedHostPercent ?? min(max(attributedCPUPercent, 0), 100)
        return (records, smoothedHostPercent != nil, totalCPUPercent)
    }

    private func buildRecord(_ item: SampledCPU, unixNow: TimeInterval) async -> RawProcess? {
        let pid = item.proc.pid
        guard let path = resolvedPath(for: item.identity, startTime: item.proc.startTime, unixNow: unixNow) else {
            return nil
        }
        let args = await arguments.arguments(for: item.identity)
        let responsible = Responsibility.pidResponsible(for: pid)
        let memory = item.canQueryTask ? Self.physicalFootprint(pid: pid) : 0
        let workingDirectory = DisplayClassifier.needsWorkspaceContext(path: path, arguments: args)
            ? ProcessWorkingDirectory.read(pid: pid)
            : nil
        return RawProcess(
            identity: item.identity,
            ppid: item.proc.ppid,
            uid: item.proc.uid,
            path: path,
            arguments: args,
            responsiblePID: responsible == 0 ? pid : responsible,
            cpuPercent: item.cpuPercent,
            memoryBytes: memory,
            workingDirectory: workingDirectory
        )
    }

    /// Same-UID CPU: Δ(user+system) and Δsystem task ticks over monotonic sampling wall time.
    private func ownedCPUPercent(
        pid: pid_t,
        identity: ProcessIdentity,
        now: TimeInterval
    ) -> (total: Double, system: Double) {
        guard let ticks = Self.cpuTicks(pid: pid) else {
            return (0, 0)
        }
        defer {
            previousCPU[identity] = CPUSample(
                totalTicks: ticks.total,
                systemTicks: ticks.system,
                wall: now
            )
        }
        guard let previous = previousCPU[identity], now > previous.wall else {
            return (0, 0)
        }
        let wall = now - previous.wall
        let totalDelta = ticks.total >= previous.totalTicks ? ticks.total - previous.totalTicks : 0
        let systemDelta = ticks.system >= previous.systemTicks ? ticks.system - previous.systemTicks : 0
        return (
            CPUTime.percent(tickDelta: totalDelta, wallSeconds: wall, logicalCores: logicalCores),
            CPUTime.percent(tickDelta: systemDelta, wallSeconds: wall, logicalCores: logicalCores)
        )
    }

    /// Other UIDs: Δ cumulative CPU seconds reported by `/bin/ps` over its midpoint clock.
    private func foreignCPUPercent(
        proc: BSDProcessMeta,
        identity: ProcessIdentity,
        wallNow: TimeInterval,
        foreign: [pid_t: ForeignProcessCPU.Sample]?
    ) -> Double {
        guard let sample = foreign?[proc.pid], sample.uid == proc.uid else {
            return 0
        }
        defer { previousForeignCPU[identity] = ForeignCPUSample(seconds: sample.seconds, wall: wallNow) }
        guard let previous = previousForeignCPU[identity], wallNow > previous.wall else {
            return 0
        }
        let delta = sample.seconds >= previous.seconds ? sample.seconds - previous.seconds : 0
        let percent = delta / (wallNow - previous.wall) * 100 / Double(logicalCores)
        return min(100, max(0, percent))
    }

    static func kernelTaskCPUPercent(
        instantHost: SystemCPULoad.Breakdown?,
        attributedTotal: Double,
        ownedSystem: Double
    ) -> Double? {
        guard let instantHost else { return nil }
        let totalGap = instantHost.totalPercent - attributedTotal
        let systemCeiling = max(0, instantHost.systemPercent - ownedSystem)
        let estimate = min(totalGap, systemCeiling)
        return estimate >= 0.5 ? estimate : nil
    }

    private func resolvedPath(
        for identity: ProcessIdentity,
        startTime: TimeInterval,
        unixNow: TimeInterval
    ) -> String? {
        let settled = unixNow - startTime >= 2.0
        if settled, let cached = pathCache[identity] {
            return cached
        }
        guard let fresh = Self.path(for: identity.pid) else { return nil }
        if settled {
            pathCache[identity] = fresh
        }
        return fresh
    }

    private static func allBSDProcesses() -> [BSDProcessMeta] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var needed = 0
        guard sysctl(&mib, 3, nil, &needed, nil, 0) == 0, needed > 0 else {
            return listPIDs().map { pid in
                let info = kinfo(for: pid)
                return BSDProcessMeta(pid: pid, ppid: info.ppid, uid: info.uid, startTime: info.startTime)
            }
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            let count = max(needed / stride, 64) + 64
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
            var length = count * stride
            let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return sysctl(&mib, 3, base, &length, nil, 0)
            }
            if status == 0 {
                let filled = length / stride
                var results: [BSDProcessMeta] = []
                results.reserveCapacity(filled)
                for index in 0..<filled {
                    let info = buffer[index]
                    let pid = info.kp_proc.p_pid
                    guard pid > 0, info.kp_proc.p_stat != SZOMB else { continue }
                    let start = TimeInterval(info.kp_proc.p_starttime.tv_sec)
                        + TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000
                    results.append(
                        BSDProcessMeta(
                            pid: pid,
                            ppid: info.kp_eproc.e_ppid,
                            uid: info.kp_eproc.e_ucred.cr_uid,
                            startTime: start
                        )
                    )
                }
                return results
            }
            guard errno == ENOMEM,
                  sysctl(&mib, 3, nil, &needed, nil, 0) == 0,
                  needed > 0
            else { break }
        }
        return []
    }

    private static func listPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(buffer.prefix(Int(filled)))
    }

    private static func path(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(procPIDPathMax))
        let length = proc_pidpath(pid, &buffer, procPIDPathMax)
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func kinfo(for pid: pid_t) -> (ppid: pid_t, startTime: TimeInterval, uid: uid_t) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return (0, 0, 0)
        }
        let start = TimeInterval(info.kp_proc.p_starttime.tv_sec)
            + TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        return (info.kp_eproc.e_ppid, start, info.kp_eproc.e_ucred.cr_uid)
    }

    private static func cpuTicks(pid: pid_t) -> (total: UInt64, system: UInt64)? {
        var task = ProcTaskInfo()
        let size = Int32(MemoryLayout<ProcTaskInfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size)
        guard result == size else { return nil }
        return (task.pti_total_user &+ task.pti_total_system, task.pti_total_system)
    }

    /// `rusage_info_v2.ri_phys_footprint` 在 uuid(16) 之后第 8 个 UInt64（下标 7）。
    private static func physicalFootprint(pid: pid_t) -> UInt64 {
        var buffer = [UInt8](repeating: 0, count: 256)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return proc_pid_rusage(pid, Int32(RUSAGE_INFO_V2), base.assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard status == 0 else { return 0 }
        let offset = 16 + MemoryLayout<UInt64>.size * 7
        guard buffer.count >= offset + 8 else { return 0 }
        return buffer.withUnsafeBytes { raw in
            raw.load(fromByteOffset: offset, as: UInt64.self)
        }
    }

    /// Synthetic read-only `kernel_task`. PID 0 keeps every safety path intact:
    /// `isProtected(pid <= 1)` blocks the end button, bulk end and doom, and
    /// `ProcessTerminator.shouldSignal` re-checks it before any `kill(2)`.
    private static func kernelTaskRecord(cpuPercent: Double) -> RawProcess {
        RawProcess(
            identity: ProcessIdentity(pid: 0, startTime: 0),
            ppid: 0,
            uid: 0,
            path: "kernel_task",
            arguments: [],
            responsiblePID: 0,
            cpuPercent: min(100, max(0, cpuPercent)),
            memoryBytes: 0
        )
    }

    private static func readPhysicalMemory() -> UInt64 {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        return max(size, 1)
    }

    private static func readMemoryUsagePercent(physicalMemory: UInt64) -> Double? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return nil
        }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }

        let page = UInt64(pageSize)
        let active = UInt64(stats.active_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let external = UInt64(stats.external_page_count) * page
        let occupied = active + inactive + wired + compressed
        let reclaimable = purgeable + external
        let used = occupied > reclaimable ? occupied - reclaimable : occupied

        return min(max(Double(used) / Double(physicalMemory) * 100, 0), 100)
    }
}
