import Foundation

nonisolated enum CPUTime {
    /// Apple Silicon 上进程 CPU 时间是 mach ticks。Rosetta 下 `mach_timebase_info` 会谎报 1/1（htop FB9546856），此时强制 125/3。
    static let nanosecondsPerMachTick: Double = {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated != 0 {
            return 125.0 / 3.0
        }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 125.0 / 3.0 }
        return Double(info.numer) / Double(info.denom)
    }()

    static func percent(tickDelta: UInt64, wallSeconds: TimeInterval, logicalCores: Int) -> Double {
        guard wallSeconds > 0, logicalCores > 0 else { return 0 }
        let cpuNanos = Double(tickDelta) * nanosecondsPerMachTick
        let wallNanos = wallSeconds * 1_000_000_000
        let value = cpuNanos / (wallNanos * Double(logicalCores)) * 100
        return min(100, max(0, value))
    }
}
