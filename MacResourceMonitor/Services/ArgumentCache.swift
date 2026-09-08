import Darwin
import Foundation

nonisolated enum ProcessArguments {
    static func read(pid: pid_t) -> [String] {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &argmax, &size, nil, 0) == 0, argmax > 0 else {
            return []
        }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var bufferSize = buffer.count
        guard sysctl(&mib, u_int(mib.count), &buffer, &bufferSize, nil, 0) == 0, bufferSize > 4 else {
            return []
        }
        let argc = buffer.withUnsafeBytes { raw -> Int32 in
            raw.load(as: Int32.self)
        }
        guard argc > 0 else { return [] }
        var index = 4
        while index < bufferSize, buffer[index] != 0 {
            index += 1
        }
        while index < bufferSize, buffer[index] == 0 {
            index += 1
        }
        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        for _ in 0..<Int(argc) {
            let start = index
            while index < bufferSize, buffer[index] != 0 {
                index += 1
            }
            if index > start {
                if let text = String(bytes: buffer[start..<index], encoding: .utf8) {
                    arguments.append(text)
                }
            }
            index += 1
            if index >= bufferSize {
                break
            }
        }
        return arguments
    }
}

actor ArgumentCache {
    private var values: [ProcessIdentity: [String]] = [:]

    func arguments(for identity: ProcessIdentity) -> [String] {
        if let cached = values[identity] {
            return cached
        }
        let read = ProcessArguments.read(pid: identity.pid)
        values[identity] = read
        return read
    }

    func prune(keeping identities: Set<ProcessIdentity>) {
        values = values.filter { identities.contains($0.key) }
    }
}
