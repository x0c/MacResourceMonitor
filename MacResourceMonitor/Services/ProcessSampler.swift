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
        var ticks: UInt64
        var wall: TimeInterval
    }

    private var previousCPU: [ProcessIdentity: CPUSample] = [:]
    private let arguments = ArgumentCache()
    private let logicalCores: Int
    private let physicalMemory: UInt64

    init() {
        self.logicalCores = max(ProcessInfo.processInfo.processorCount, 1)
        self.physicalMemory = Self.readPhysicalMemory()
    }

    var memoryBytes: UInt64 { physicalMemory }

    var memoryUsagePercent: Double? {
        Self.readMemoryUsagePercent(physicalMemory: physicalMemory)
    }

    func snapshot() async -> (records: [RawProcess], cpuSampleReady: Bool) {
        let pids = Self.listPIDs()
        let now = CFAbsoluteTimeGetCurrent()
        var records: [RawProcess] = []
        records.reserveCapacity(pids.count)
        var live: Set<ProcessIdentity> = []
        var cpuSampleReady = false

        for pid in pids {
            guard let result = await sample(pid: pid, now: now) else { continue }
            records.append(result.record)
            live.insert(result.record.identity)
            cpuSampleReady = cpuSampleReady || result.cpuSampleReady
        }

        previousCPU = previousCPU.filter { live.contains($0.key) }
        await arguments.prune(keeping: live)
        return (records, cpuSampleReady)
    }

    private func sample(
        pid: pid_t,
        now: TimeInterval
    ) async -> (record: RawProcess, cpuSampleReady: Bool)? {
        guard pid > 0 else { return nil }
        guard let path = Self.path(for: pid) else { return nil }
        let info = Self.kinfo(for: pid)
        let identity = ProcessIdentity(pid: pid, startTime: info.startTime)
        let args = await arguments.arguments(for: identity)
        let responsible = Responsibility.pidResponsible(for: pid)
        let ticks = Self.cpuTicks(pid: pid)
        let cpu: Double
        var cpuSampleReady = false
        if let ticks {
            if let previous = previousCPU[identity], now > previous.wall {
                let delta = ticks >= previous.ticks ? ticks - previous.ticks : 0
                cpu = CPUTime.percent(tickDelta: delta, wallSeconds: now - previous.wall, logicalCores: logicalCores)
                cpuSampleReady = true
            } else {
                cpu = 0
            }
            previousCPU[identity] = CPUSample(ticks: ticks, wall: now)
        } else {
            cpu = 0
        }
        let memory = Self.physicalFootprint(pid: pid)
        return (
            RawProcess(
                identity: identity,
                ppid: info.ppid,
                uid: info.uid,
                path: path,
                arguments: args,
                responsiblePID: responsible == 0 ? pid : responsible,
                cpuPercent: cpu,
                memoryBytes: memory
            ),
            cpuSampleReady
        )
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

    private static func cpuTicks(pid: pid_t) -> UInt64? {
        var task = ProcTaskInfo()
        let size = Int32(MemoryLayout<ProcTaskInfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size)
        guard result == size else { return nil }
        return task.pti_total_user &+ task.pti_total_system
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
