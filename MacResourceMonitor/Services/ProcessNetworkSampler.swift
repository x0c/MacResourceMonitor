import Foundation

/// 使用系统自带 nettop 的一秒差分计算实时速率；应用启动后后台预热，不依赖网络表是否展开。
actor ProcessNetworkSampler {
    func sample() async -> [pid_t: ProcessNetworkRate] {
        let output = await Task.detached(priority: .utility) {
            Self.nettopRates()
        }.value
        return Self.parse(output).reduce(into: [:]) { rates, entry in
            let (pid, counters) = entry
            guard counters.received > 0 || counters.sent > 0 else { return }
            rates[pid] = ProcessNetworkRate(
                receivedBytesPerSecond: Double(counters.received),
                sentBytesPerSecond: Double(counters.sent)
            )
        }
    }

    nonisolated static func parse(_ output: String) -> [pid_t: (received: UInt64, sent: UInt64)] {
        var counters: [pid_t: (received: UInt64, sent: UInt64)] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3,
                  let lastDot = columns[0].lastIndex(of: "."),
                  let pidNumber = Int32(columns[0][columns[0].index(after: lastDot)...]),
                  let received = UInt64(columns[1]),
                  let sent = UInt64(columns[2])
            else { continue }
            counters[pid_t(pidNumber)] = (received, sent)
        }
        return counters
    }

    private nonisolated static func nettopRates() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -d 输出区间增量；两帧、每秒一帧，首帧作基线、第二帧就是一秒速率。
        task.arguments = ["-d", "-P", "-L", "2", "-s", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return ""
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
