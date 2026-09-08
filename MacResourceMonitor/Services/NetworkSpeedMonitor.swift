import Darwin
import Foundation
import Network

nonisolated struct NetworkInterfaceCounters: Equatable {
    let bytesIn: UInt64
    let bytesOut: UInt64
}

/// 菜单栏只读当前默认外网出口；切换出口后先重新取基线，不能把旧接口累计字节当成新网速。
@MainActor
final class NetworkSpeedMonitor {
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "top.caozc.MacResourceMonitor.network-path")
    private var sampleTimer: Timer?
    private var defaultInterfaceName: String?
    private var baseline: (counters: NetworkInterfaceCounters, uptime: TimeInterval)?
    private var observer: ((Double?, Double?) -> Void)?

    func setObserver(_ observer: @escaping (Double?, Double?) -> Void) {
        self.observer = observer
        observer(nil, nil)
    }

    func start() {
        guard sampleTimer == nil else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let interfaceName = path.status == .satisfied ? Self.defaultRouteInterfaceName() : nil
            Task { @MainActor [weak self] in
                self?.setDefaultInterface(interfaceName)
            }
        }
        pathMonitor.start(queue: pathQueue)
        setDefaultInterface(Self.defaultRouteInterfaceName())
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
    }

    func stop() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        pathMonitor.cancel()
        baseline = nil
    }

    private func setDefaultInterface(_ interfaceName: String?) {
        guard defaultInterfaceName != interfaceName else { return }
        defaultInterfaceName = interfaceName
        baseline = nil
        observer?(nil, nil)
    }

    private func sample() {
        guard let defaultInterfaceName,
              let counters = Self.interfaceCounters(named: defaultInterfaceName)
        else {
            baseline = nil
            observer?(nil, nil)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard let baseline else {
            self.baseline = (counters, now)
            observer?(nil, nil)
            return
        }

        let elapsed = now - baseline.uptime
        guard elapsed > 0,
              counters.bytesIn >= baseline.counters.bytesIn,
              counters.bytesOut >= baseline.counters.bytesOut
        else {
            self.baseline = (counters, now)
            observer?(nil, nil)
            return
        }

        self.baseline = (counters, now)
        let download = Double(counters.bytesIn - baseline.counters.bytesIn) / elapsed
        let upload = Double(counters.bytesOut - baseline.counters.bytesOut) / elapsed
        observer?(upload, download)
    }

    nonisolated static func defaultRouteInterfaceName(from routeOutput: String) -> String? {
        for line in routeOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespacesAndNewlines) == "interface"
            else { continue }
            let name = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    nonisolated private static func defaultRouteInterfaceName() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/route")
        task.arguments = ["-n", "get", "default"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let routeOutput = String(data: data, encoding: .utf8)
        else { return nil }
        return defaultRouteInterfaceName(from: routeOutput)
    }

    nonisolated private static func interfaceCounters(named interfaceName: String) -> NetworkInterfaceCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return nil }

        for _ in 0..<3 {
            var length = needed
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 {
                return counters(named: interfaceName, in: buffer, length: length)
            }
            guard errno == ENOMEM,
                  sysctl(&mib, 6, nil, &needed, nil, 0) == 0
            else { return nil }
        }
        return nil
    }

    nonisolated private static func counters(
        named interfaceName: String,
        in buffer: [UInt8],
        length: Int
    ) -> NetworkInterfaceCounters? {
        return buffer.withUnsafeBytes { raw -> NetworkInterfaceCounters? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let message = base.advanced(by: offset)
                let header = message.assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }

                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      messageLength >= MemoryLayout<if_msghdr2>.size + MemoryLayout<sockaddr_dl>.size
                else { continue }

                let header2 = message.assumingMemoryBound(to: if_msghdr2.self).pointee
                let link = message.advanced(by: MemoryLayout<if_msghdr2>.size)
                    .assumingMemoryBound(to: sockaddr_dl.self).pointee
                guard interfaceNameFromLink(link) == interfaceName else { continue }

                return NetworkInterfaceCounters(
                    bytesIn: header2.ifm_data.ifi_ibytes,
                    bytesOut: header2.ifm_data.ifi_obytes
                )
            }
            return nil
        }
    }

    nonisolated private static func interfaceNameFromLink(_ link: sockaddr_dl) -> String {
        let nameLength = Int(link.sdl_nlen)
        guard nameLength > 0 else { return "" }
        return withUnsafeBytes(of: link.sdl_data) { bytes in
            let length = min(nameLength, bytes.count)
            return String(decoding: bytes.prefix(length).map { UInt8($0) }, as: UTF8.self)
        }
    }
}

/// 网速只展示 KB/s、MB/s 或 GB/s，避免 K/M/G 这种没有单位的缩写。
nonisolated struct NetworkRatePair: Equatable {
    let upload: String
    let download: String
    let unit: String?
}

/// 表格里数字与单位拆开排：数字跟百分比同号，单位更小一号，避免大写 `KB/s` 把整格撑大。
nonisolated struct NetworkRateTextParts: Equatable {
    let value: String
    let unit: String?
}

nonisolated enum NetworkRateFormatter {
    static func text(for bytesPerSecond: Double?) -> String {
        let parts = parts(for: bytesPerSecond)
        guard let unit = parts.unit else { return parts.value }
        return "\(parts.value) \(unit)"
    }

    static func parts(for bytesPerSecond: Double?) -> NetworkRateTextParts {
        guard let bytesPerSecond, bytesPerSecond >= 0 else {
            return NetworkRateTextParts(value: "—", unit: nil)
        }
        let unit = unit(for: bytesPerSecond)
        return NetworkRateTextParts(
            value: valueText(for: bytesPerSecond, unit: unit),
            unit: unit.label
        )
    }

    static func pair(
        uploadBytesPerSecond: Double?,
        downloadBytesPerSecond: Double?
    ) -> NetworkRatePair {
        guard let uploadBytesPerSecond, uploadBytesPerSecond >= 0,
              let downloadBytesPerSecond, downloadBytesPerSecond >= 0
        else {
            return NetworkRatePair(upload: "—", download: "—", unit: nil)
        }

        let unit = unit(for: max(uploadBytesPerSecond, downloadBytesPerSecond))
        return NetworkRatePair(
            upload: valueText(for: uploadBytesPerSecond, unit: unit),
            download: valueText(for: downloadBytesPerSecond, unit: unit),
            unit: unit.label
        )
    }

    private static func unit(for bytesPerSecond: Double) -> NetworkRateUnit {
        // 展示整数不得超过三位：再高就升档，固定菜单栏宽度才压得住左侧留白。
        let kilobytes = bytesPerSecond / 1_024
        if kilobytes < 999.5 {
            return .kilobytes
        }
        let megabytes = bytesPerSecond / (1_024 * 1_024)
        if megabytes < 999.5 {
            return .megabytes
        }
        return .gigabytes
    }

    private static func valueText(for bytesPerSecond: Double, unit: NetworkRateUnit) -> String {
        let value = bytesPerSecond / unit.divisor
        guard value > 0 else { return "0" }
        // 不足一个当前单位仍显示 <1（含升档边界上略低于 1 的峰值）。
        if value < 1 { return "<1" }
        return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value.rounded())
    }
}

nonisolated private enum NetworkRateUnit {
    case kilobytes
    case megabytes
    case gigabytes

    var divisor: Double {
        switch self {
        case .kilobytes: 1_024
        case .megabytes: 1_024 * 1_024
        case .gigabytes: 1_024 * 1_024 * 1_024
        }
    }

    var label: String {
        switch self {
        case .kilobytes: "KB/s"
        case .megabytes: "MB/s"
        case .gigabytes: "GB/s"
        }
    }
}
