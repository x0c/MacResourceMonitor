import Darwin
import Foundation

/// Long-lived `nettop` stream over a PTY — same pattern as mac-stats.
/// One child emits CSV about once per second; avoids spawn-per-sample CPU cost.
///
/// On current macOS, `-J bytes_in,bytes_out` yields:
///   `,bytes_in,bytes_out,`
///   `name.pid,bytes_in,bytes_out,`
/// (no `time` column). First `-d` frame is a baseline; real rates start on the second.
nonisolated final class NettopStreamSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Process?
    private var masterHandle: FileHandle?
    /// Keep the slave end alive for the Process lifetime (shared stdin/stdout).
    private var slaveHandle: FileHandle?
    private var buffer = [UInt8]()
    private var bufferHead = 0
    private var latestRates: [pid_t: ProcessNetworkRate] = [:]
    private var currentFrame: [pid_t: ProcessNetworkRate] = [:]
    private var headersSeen = 0
    private var hasPublishedFrame = false

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // `-d` = per-interval deltas; `-L 0` = stream forever; PTY required (Pipe buffers forever).
        process.arguments = [
            "-d", "-P", "-L", "0", "-s", "1", "-x", "-n",
            "-J", "bytes_in,bytes_out"
        ]
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = FileHandle.nullDevice

        masterHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.handleChunk(chunk)
        }

        do {
            try process.run()
            self.task = process
            self.masterHandle = masterHandle
            self.slaveHandle = slaveHandle
            buffer.removeAll(keepingCapacity: true)
            bufferHead = 0
            latestRates = [:]
            currentFrame = [:]
            headersSeen = 0
            hasPublishedFrame = false
        } catch {
            masterHandle.readabilityHandler = nil
            try? masterHandle.close()
            try? slaveHandle.close()
        }
    }

    func stop() {
        lock.lock()
        masterHandle?.readabilityHandler = nil
        let dyingTask = task
        let dyingMaster = masterHandle
        let dyingSlave = slaveHandle
        task = nil
        masterHandle = nil
        slaveHandle = nil
        latestRates = [:]
        currentFrame = [:]
        headersSeen = 0
        hasPublishedFrame = false
        buffer.removeAll(keepingCapacity: true)
        bufferHead = 0
        lock.unlock()

        // Tear down handles AFTER releasing the lock: closeFile() can flush a
        // final readabilityHandler callback that re-enters handleChunk → NSLock
        // is not re-entrant, so closing under the lock self-deadlocks the
        // fd_monitoring queue (and the orphaned nettop child keeps its PTY,
        // spinning at ~130% CPU with PPID 1 — the 2026-09-13 fan incident).
        // Clearing task=nil under the lock first makes those late chunks no-ops.
        dyingMaster?.readabilityHandler = nil
        try? dyingMaster?.close()
        try? dyingSlave?.close()

        guard let dyingTask else { return }
        dyingTask.terminate()
        let pid = dyingTask.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if dyingTask.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    func latestRatesSnapshot() -> [pid_t: ProcessNetworkRate] {
        lock.lock()
        defer { lock.unlock() }
        return latestRates
    }

    var hasFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasPublishedFrame
    }

    // Internal for testing: regression test feeds synthetic chunks concurrently
    // with stop()/start() to prove the buffer is lock-protected.
    func handleChunk(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        // stop() sets task=nil under the same lock; drop late chunks after stop
        // instead of appending to a cleared buffer (ex-index-out-of-range crash).
        guard task != nil else { return }
        chunk.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            let bytes = UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self),
                count: raw.count
            )
            buffer.append(contentsOf: bytes)
        }

        let count = buffer.count
        var lineStart = bufferHead
        var index = bufferHead
        while index < count {
            if buffer[index] == 0x0A {
                handleLineLocked(start: lineStart, end: index)
                lineStart = index + 1
            }
            index += 1
        }
        bufferHead = lineStart

        if bufferHead >= 4096 {
            buffer.removeFirst(bufferHead)
            bufferHead = 0
        }
    }

    /// Must be called with `lock` held (see handleChunk). Split out so the whole
    /// chunk — append, split, parse, publish — is atomic vs stop()/start().
    /// Previously handleChunk touched `buffer` without the lock while stop()
    /// cleared it on another thread: `buffer[index]` then trapped Index out of
    /// range on the NSFileHandle.fd_monitoring queue (2026-09-13 闪退).
    private func handleLineLocked(start: Int, end: Int) {
        var realEnd = end
        if realEnd > start, buffer[realEnd - 1] == 0x0D { realEnd -= 1 }
        guard realEnd > start else { return }

        if Self.isHeaderLine(buffer, start: start, end: realEnd) {
            // First completed body is the `-d` baseline; publish from the second body onward.
            if headersSeen >= 2 {
                latestRates = currentFrame
                hasPublishedFrame = true
            }
            currentFrame = [:]
            headersSeen += 1
            return
        }

        guard headersSeen >= 1 else { return }
        guard let parsed = Self.parseDeltaLine(buffer, start: start, end: realEnd) else { return }
        guard parsed.received > 0 || parsed.sent > 0 else { return }

        currentFrame[parsed.pid] = ProcessNetworkRate(
            receivedBytesPerSecond: Double(parsed.received),
            sentBytesPerSecond: Double(parsed.sent)
        )
    }

    /// Header is `,bytes_in,bytes_out,` (current `-J`) or legacy `time,...bytes_in...`.
    nonisolated static func isHeaderLine(_ buffer: [UInt8], start: Int, end: Int) -> Bool {
        guard end > start else { return false }
        let slice = buffer[start..<end]
        // Fast path: `,bytes_in,bytes_out`
        if slice.count >= 10,
           slice[start] == 0x2C, // ,
           slice[start + 1] == 0x62, // b
           slice[start + 2] == 0x79, // y
           slice[start + 3] == 0x74, // t
           slice[start + 4] == 0x65, // e
           slice[start + 5] == 0x73, // s
           slice[start + 6] == 0x5F // _
        {
            return true
        }
        // Legacy: `time,`
        if slice.count >= 5,
           slice[start] == 0x74,
           slice[start + 1] == 0x69,
           slice[start + 2] == 0x6D,
           slice[start + 3] == 0x65,
           slice[start + 4] == 0x2C
        {
            return true
        }
        return false
    }

    private struct ParsedDelta {
        var pid: pid_t
        var received: UInt64
        var sent: UInt64
    }

    /// Supports both:
    /// - `name.pid,bytes_in,bytes_out,`  (current `-J`)
    /// - `time,name.pid,bytes_in,bytes_out,`  (legacy)
    private static func parseDeltaLine(
        _ buffer: [UInt8],
        start: Int,
        end: Int
    ) -> ParsedDelta? {
        var commas: [Int] = []
        commas.reserveCapacity(4)
        var index = start
        while index < end {
            if buffer[index] == 0x2C {
                commas.append(index)
                if commas.count == 4 { break }
            }
            index += 1
        }

        let nameStart: Int
        let nameEnd: Int
        let inStart: Int
        let inEnd: Int
        let outStart: Int
        let outEnd: Int

        if commas.count >= 3, commas[0] == start {
            // `,bytes_in,...` is a header — reject.
            return nil
        }

        if commas.count >= 3 {
            // Prefer `name.pid,in,out[,]` when first field is a process and the next two are integers.
            let candidateNameStart = start
            let candidateNameEnd = commas[0]
            let candidateInOK = parseUInt64(in: buffer, start: commas[0] + 1, end: commas[1]) != nil
            let candidateOutOK = parseUInt64(in: buffer, start: commas[1] + 1, end: commas[2]) != nil
            if candidateInOK,
               candidateOutOK,
               parsePID(in: buffer, start: candidateNameStart, end: candidateNameEnd) != nil
            {
                nameStart = candidateNameStart
                nameEnd = candidateNameEnd
                inStart = commas[0] + 1
                inEnd = commas[1]
                outStart = commas[1] + 1
                outEnd = commas[2]
            } else if commas.count >= 4 {
                // `time,name.pid,in,out`
                nameStart = commas[0] + 1
                nameEnd = commas[1]
                inStart = commas[1] + 1
                inEnd = commas[2]
                outStart = commas[2] + 1
                outEnd = commas[3]
            } else {
                return nil
            }
        } else {
            return nil
        }

        guard let pid = parsePID(in: buffer, start: nameStart, end: nameEnd),
              let received = parseUInt64(in: buffer, start: inStart, end: inEnd),
              let sent = parseUInt64(in: buffer, start: outStart, end: outEnd)
        else { return nil }

        return ParsedDelta(pid: pid, received: received, sent: sent)
    }

    /// Parse a single CSV line from a UTF-8 string (tests / diagnostics).
    nonisolated static func parseLine(_ line: String) -> (pid: pid_t, received: UInt64, sent: UInt64)? {
        let bytes = Array(line.utf8)
        guard let parsed = parseDeltaLine(bytes, start: 0, end: bytes.count) else { return nil }
        return (parsed.pid, parsed.received, parsed.sent)
    }

    nonisolated static func isHeader(_ line: String) -> Bool {
        let bytes = Array(line.utf8)
        return isHeaderLine(bytes, start: 0, end: bytes.count)
    }

    private static func parsePID(in buffer: [UInt8], start: Int, end: Int) -> pid_t? {
        var dotIndex: Int?
        var index = end - 1
        while index > start {
            if buffer[index] == 0x2E {
                dotIndex = index
                break
            }
            index -= 1
        }
        guard let dotIndex, dotIndex + 1 < end else { return nil }
        var pid: Int32 = 0
        var digitIndex = dotIndex + 1
        while digitIndex < end {
            let byte = buffer[digitIndex]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            pid = pid * 10 + Int32(byte - 0x30)
            digitIndex += 1
        }
        return pid > 0 ? pid_t(pid) : nil
    }

    private static func parseUInt64(in buffer: [UInt8], start: Int, end: Int) -> UInt64? {
        guard start < end else { return 0 }
        var value: UInt64 = 0
        var index = start
        while index < end {
            let byte = buffer[index]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + UInt64(byte - 0x30)
            index += 1
        }
        return value
    }
}
