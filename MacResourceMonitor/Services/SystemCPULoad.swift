import Darwin
import Foundation

/// Machine-wide CPU ticks from the kernel, the only source that includes
/// `kernel_task`, cross-UID services and processes shorter than one sample.
/// Percentages are shares of all logical cores, so 0–100% matches the product's
/// "整机逻辑核占比" wording; per-process CPU keeps using `CPUTime.percent`.
nonisolated struct SystemCPULoad: Equatable, Sendable {
    struct Breakdown: Equatable, Sendable {
        var totalPercent: Double
        var systemPercent: Double
    }

    var userTicks: UInt64
    var systemTicks: UInt64
    var totalTicks: UInt64

    var busyTicks: UInt64 { userTicks &+ systemTicks }

    init(userTicks: UInt64, systemTicks: UInt64, totalTicks: UInt64) {
        self.userTicks = userTicks
        self.systemTicks = systemTicks
        self.totalTicks = totalTicks
    }

    init(busyTicks: UInt64, totalTicks: UInt64) {
        self.userTicks = busyTicks
        self.systemTicks = 0
        self.totalTicks = totalTicks
    }

    static func read() -> SystemCPULoad? {
        var stats = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        // cpu_ticks order is CPU_STATE_USER, SYSTEM, IDLE, NICE.
        let user = UInt64(stats.cpu_ticks.0) &+ UInt64(stats.cpu_ticks.3)
        let system = UInt64(stats.cpu_ticks.1)
        let idle = UInt64(stats.cpu_ticks.2)
        return SystemCPULoad(
            userTicks: user,
            systemTicks: system,
            totalTicks: user &+ system &+ idle
        )
    }

    /// Busy and kernel-system shares between two reads, clamped to 0–100%.
    func breakdown(since previous: SystemCPULoad) -> Breakdown? {
        guard totalTicks > previous.totalTicks,
              userTicks >= previous.userTicks,
              systemTicks >= previous.systemTicks,
              busyTicks >= previous.busyTicks
        else {
            return nil
        }
        let busy = busyTicks - previous.busyTicks
        let system = systemTicks - previous.systemTicks
        let total = totalTicks - previous.totalTicks
        return Breakdown(
            totalPercent: min(100, max(0, Double(busy) / Double(total) * 100)),
            systemPercent: min(100, max(0, Double(system) / Double(total) * 100))
        )
    }

    /// Busy share between two reads, clamped to 0–100%.
    func percent(since previous: SystemCPULoad) -> Double? {
        breakdown(since: previous)?.totalPercent
    }
}
