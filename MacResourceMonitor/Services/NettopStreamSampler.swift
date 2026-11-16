import Darwin
import Foundation

/// Long-lived `nettop` stream over a PTY with fast initial cumulative diffing.
///
/// On current macOS, `-J bytes_in,bytes_out` yields:
///   `,bytes_in,bytes_out,`
///   `name.pid,bytes_in,bytes_out,`
/// (no `time` column). Running cumulative counters (without `-d`) lets us flush each
/// burst as soon as the line boundary settles (~25ms) instead of waiting for the next
/// second's header, and pair the initial baseline (~22ms) with one fast `-L 1` probe
/// (~200ms later) so opening the network table produces live rates in ~250ms.
nonisolated final class NettopStreamSampler: @unchecked Sendable {
    static let executablePath = "/usr/bin/nettop"
    /// Cumulative per-process stream over PTY (Pipe block-buffers ~4KB without a TTY).
    static let arguments = [
        "-P", "-L", "0", "-s", "1", "-x", "-n",
        "-J", "bytes_in,bytes_out"
    ]
    static let singleShotArguments = [
        "-P", "-L", "1", "-x", "-n",
        "-J", "bytes_in,bytes_out"
    ]

    private let lock = NSLock()
    private let flushQueue = DispatchQueue(label: "top.caozc.MacResourceMonitor.nettop-flush")
    private let probeQueue = DispatchQueue(label: "top.caozc.MacResourceMonitor.nettop-probe", qos: .userInitiated)
    private var generation: UInt64 = 0
    private var task: Process?
    private var probeTask: Process?
    private var masterHandle: FileHandle?
    /// Keep the slave end alive for the Process lifetime (shared stdin/stdout).
    private var slaveHandle: FileHandle?
    private var pendingFlushWorkItem: DispatchWorkItem?
    private var buffer = [UInt8]()
    private var bufferHead = 0
    private var currentCounters: [pid_t: (received: UInt64, sent: UInt64)] = [:]
    private var baselineCounters: [pid_t: (received: UInt64, sent: UInt64)]?
    private var baselineTimestamp: ContinuousClock.Instant?
    private var latestRates: [pid_t: ProcessNetworkRate] = [:]
    private var headersSeen = 0
    private var currentFrameOpen = false
    private var hasPublishedFrame = false
    private var publishedSequence: UInt64 = 0
    private var probeScheduled = false
    private var frameWaiters: [UUID: (minSequence: UInt64, callback: @Sendable () -> Void)] = [:]

    deinit {
        stop()
    }

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
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = Self.arguments
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
            generation &+= 1
            self.task = process
            self.probeTask = nil
            self.masterHandle = masterHandle
            self.slaveHandle = slaveHandle
            pendingFlushWorkItem?.cancel()
            pendingFlushWorkItem = nil
            buffer.removeAll(keepingCapacity: true)
            bufferHead = 0
            currentCounters.removeAll(keepingCapacity: true)
            baselineCounters = nil
            baselineTimestamp = nil
            latestRates = [:]
            headersSeen = 0
            currentFrameOpen = false
            hasPublishedFrame = false
            publishedSequence = 0
            probeScheduled = false
        } catch {
            masterHandle.readabilityHandler = nil
            try? masterHandle.close()
            try? slaveHandle.close()
        }
    }

    func stop() {
        lock.lock()
        generation &+= 1
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil
        masterHandle?.readabilityHandler = nil
        let dyingTask = task
        let dyingProbeTask = probeTask
        let dyingMaster = masterHandle
        let dyingSlave = slaveHandle
        let waiters = frameWaiters.values.map(\.callback)
        frameWaiters.removeAll(keepingCapacity: true)
        task = nil
        probeTask = nil
        masterHandle = nil
        slaveHandle = nil
        currentCounters.removeAll(keepingCapacity: true)
        baselineCounters = nil
        baselineTimestamp = nil
        latestRates = [:]
        headersSeen = 0
        currentFrameOpen = false
        hasPublishedFrame = false
        publishedSequence = 0
        probeScheduled = false
        buffer.removeAll(keepingCapacity: true)
        bufferHead = 0
        lock.unlock()

        for waiter in waiters {
            waiter()
        }

        // Tear down handles AFTER releasing the lock: closeFile() can flush a
        // final readabilityHandler callback that re-enters handleChunk → NSLock
        // is not re-entrant, so closing under the lock self-deadlocks the
        // fd_monitoring queue (and the orphaned nettop child keeps its PTY,
        // spinning at ~130% CPU with PPID 1 — the 2026-09-13 fan incident).
        // Clearing task=nil under the lock first makes those late chunks no-ops.
        dyingMaster?.readabilityHandler = nil
        try? dyingMaster?.close()
        try? dyingSlave?.close()

        Self.terminateAndReap(dyingProbeTask)
        Self.terminateAndReap(dyingTask)
    }

    private static func terminateAndReap(_ dyingTask: Process?) {
        guard let dyingTask else { return }
        let pid = dyingTask.processIdentifier
        dyingTask.terminate()
        // Must reap before this process exits. An async follow-up SIGKILL is
        // lost on quit / coverage-install, leaving PPID=1 spinners named "0".
        let deadline = Date().addingTimeInterval(0.2)
        while dyingTask.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if dyingTask.isRunning {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    /// Kill leftover samplers from a previous instance (quit, crash, overlay install).
    static func reapOrphanedSamplers(keeping pidToKeep: pid_t? = nil) {
        let selfPID = getpid()
        let uid = getuid()
        for pid in listPIDs() {
            if pid == selfPID { continue }
            if let pidToKeep, pid == pidToKeep { continue }
            guard let executable = processPath(for: pid), isSamplerExecutable(executable) else { continue }
            let meta = processMeta(for: pid)
            guard meta.uid == uid else { continue }
            guard isSamplerProcess(path: executable, arguments: ProcessArguments.read(pid: pid)) else { continue }
            let isOrphan = meta.ppid <= 1
            let isForeignMonitorChild: Bool = {
                guard meta.ppid > 1, meta.ppid != selfPID else { return false }
                guard let parentPath = processPath(for: meta.ppid) else { return true }
                return parentPath.contains("/Mac Resource Monitor.app/")
            }()
            guard isOrphan || isForeignMonitorChild else { continue }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    static func isSamplerExecutable(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "nettop"
    }

    static func isSamplerProcess(path: String, arguments: [String]) -> Bool {
        isSamplerExecutable(path) && matchesSamplerArguments(arguments)
    }

    static func matchesSamplerArguments(_ arguments: [String]) -> Bool {
        let flags: [String]
        if let first = arguments.first, URL(fileURLWithPath: first).lastPathComponent == "nettop" {
            flags = Array(arguments.dropFirst())
        } else {
            flags = arguments
        }
        if flags == Self.arguments || flags == Self.singleShotArguments { return true }
        // Verified 2026-10-07: nettop rewrites its own argv at runtime — a sampler
        // launched with `-J bytes_in,bytes_out` reads back from the kernel as
        // `-J bytes_in`. Match both legacy `-d` streams and current cumulative `-L 0` /
        // `-L 1` samplers carrying `-P -L -x -n -J bytes_in...`.
        // Caller only kills orphans / foreign monitor children of the same UID,
        // so a user's own foreground nettop is never matched here for killing.
        guard flags.contains("-P"), flags.contains("-L"),
              flags.contains("-x"), flags.contains("-n"),
              flags.contains("-J"),
              let jIndex = flags.firstIndex(of: "-J"), jIndex + 1 < flags.count
        else { return false }
        let columns = flags[jIndex + 1].split(separator: ",")
        return columns.contains(where: { $0 == "bytes_in" || $0 == "bytes_out" })
    }

    private static func listPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(buffer.prefix(Int(filled)))
    }

    private static func processPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func processMeta(for pid: pid_t) -> (ppid: pid_t, uid: uid_t) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return (0, 0)
        }
        return (info.kp_eproc.e_ppid, info.kp_eproc.e_ucred.cr_uid)
    }

    func latestSampleSnapshot() -> (hasFrame: Bool, sequence: UInt64, rates: [pid_t: ProcessNetworkRate]) {
        lock.lock()
        defer { lock.unlock() }
        return (hasPublishedFrame, publishedSequence, latestRates)
    }

    func latestRatesSnapshot() -> [pid_t: ProcessNetworkRate] {
        latestSampleSnapshot().rates
    }

    var hasFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasPublishedFrame
    }

    func waitForFirstFrame(timeoutSeconds: Double = 1.5) async {
        await waitForNextFrame(after: 0, timeoutSeconds: timeoutSeconds)
    }

    func waitForNextFrame(after sequence: UInt64, timeoutSeconds: Double = 1.25) async {
        guard !Task.isCancelled else { return }
        start()
        let waiterID = UUID()
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            init(_ continuation: CheckedContinuation<Void, Never>) {
                self.continuation = continuation
            }
            func resume() {
                lock.lock()
                let pending = continuation
                continuation = nil
                lock.unlock()
                pending?.resume()
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let box = ResumeOnce(continuation)
                lock.lock()
                if Task.isCancelled || publishedSequence > sequence || task == nil {
                    lock.unlock()
                    box.resume()
                    return
                }
                frameWaiters[waiterID] = (
                    minSequence: sequence + 1,
                    callback: { [weak self] in
                        self?.removeWaiter(id: waiterID)
                        box.resume()
                    }
                )
                lock.unlock()

                flushQueue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    self?.removeWaiter(id: waiterID)
                    box.resume()
                }
            }
        } onCancel: { [weak self] in
            let callback = self?.removeWaiter(id: waiterID)
            callback?()
        }
    }

    @discardableResult
    private func removeWaiter(id: UUID) -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return frameWaiters.removeValue(forKey: id)?.callback
    }

    // Internal for testing: regression test feeds synthetic chunks concurrently
    // with stop()/start() to prove the buffer is lock-protected.
    func handleChunk(_ chunk: Data) {
        var callbacksToInvoke: [@Sendable () -> Void] = []
        var probeGenToSchedule: UInt64?

        lock.lock()
        // stop() sets task=nil under the same lock; drop late chunks after stop
        // instead of appending to a cleared buffer (ex-index-out-of-range crash).
        guard task != nil else {
            lock.unlock()
            return
        }
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil

        chunk.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            let bytes = UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self),
                count: raw.count
            )
            buffer.append(contentsOf: bytes)
        }

        let now = ContinuousClock.now
        let count = buffer.count
        var lineStart = bufferHead
        var index = bufferHead
        while index < count {
            if buffer[index] == 0x0A {
                let outcome = handleLineLocked(start: lineStart, end: index, now: now)
                if !outcome.waiters.isEmpty {
                    callbacksToInvoke.append(contentsOf: outcome.waiters)
                }
                if let gen = outcome.scheduleProbeGeneration {
                    probeGenToSchedule = gen
                }
                lineStart = index + 1
            }
            index += 1
        }
        bufferHead = lineStart

        if bufferHead >= 4096 {
            buffer.removeFirst(bufferHead)
            bufferHead = 0
        }

        if currentFrameOpen, bufferHead == buffer.count {
            let expectedGeneration = generation
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushOpenFrameIfSettled(expectedGeneration: expectedGeneration)
            }
            pendingFlushWorkItem = workItem
            flushQueue.asyncAfter(deadline: .now() + .milliseconds(25), execute: workItem)
        }
        lock.unlock()

        for callback in callbacksToInvoke {
            callback()
        }
        if let gen = probeGenToSchedule {
            scheduleInitialProbe(for: gen)
        }
    }

    private func flushOpenFrameIfSettled(expectedGeneration: UInt64) {
        var callbacksToInvoke: [@Sendable () -> Void] = []
        var probeGenToSchedule: UInt64?

        lock.lock()
        guard task != nil,
              generation == expectedGeneration,
              currentFrameOpen,
              bufferHead == buffer.count
        else {
            lock.unlock()
            return
        }
        let outcome = commitCurrentFrameLocked(at: ContinuousClock.now)
        callbacksToInvoke = outcome.waiters
        probeGenToSchedule = outcome.scheduleProbeGeneration
        lock.unlock()

        for callback in callbacksToInvoke {
            callback()
        }
        if let gen = probeGenToSchedule {
            scheduleInitialProbe(for: gen)
        }
    }

    /// Must be called with `lock` held (see handleChunk). Split out so the whole
    /// chunk — append, split, parse, publish — is atomic vs stop()/start().
    private func handleLineLocked(
        start: Int,
        end: Int,
        now: ContinuousClock.Instant
    ) -> (waiters: [@Sendable () -> Void], scheduleProbeGeneration: UInt64?) {
        var realEnd = end
        if realEnd > start, buffer[realEnd - 1] == 0x0D { realEnd -= 1 }
        guard realEnd > start else { return ([], nil) }

        if Self.isHeaderLine(buffer, start: start, end: realEnd) {
            var outcome: (waiters: [@Sendable () -> Void], scheduleProbeGeneration: UInt64?) = ([], nil)
            if currentFrameOpen {
                outcome = commitCurrentFrameLocked(at: now)
            }
            currentCounters.removeAll(keepingCapacity: true)
            currentFrameOpen = true
            headersSeen += 1
            return outcome
        }

        guard headersSeen >= 1, currentFrameOpen else { return ([], nil) }
        guard let parsed = Self.parseDeltaLine(buffer, start: start, end: realEnd) else {
            return ([], nil)
        }
        currentCounters[parsed.pid] = (parsed.received, parsed.sent)
        return ([], nil)
    }

    private func commitCurrentFrameLocked(
        at now: ContinuousClock.Instant
    ) -> (waiters: [@Sendable () -> Void], scheduleProbeGeneration: UInt64?) {
        currentFrameOpen = false
        return applyCumulativeSnapshotLocked(currentCounters, at: now)
    }

    private func applyCumulativeSnapshotLocked(
        _ snapshot: [pid_t: (received: UInt64, sent: UInt64)],
        at now: ContinuousClock.Instant,
        overrideElapsedSeconds: Double? = nil
    ) -> (waiters: [@Sendable () -> Void], scheduleProbeGeneration: UInt64?) {
        guard let previous = baselineCounters, let previousTime = baselineTimestamp else {
            baselineCounters = snapshot
            baselineTimestamp = now
            if !hasPublishedFrame, !probeScheduled {
                probeScheduled = true
                return ([], generation)
            }
            return ([], nil)
        }

        let elapsed = overrideElapsedSeconds ?? Self.seconds(from: previousTime, to: now)
        let safeElapsed = max(elapsed, 0.05)
        var nextRates: [pid_t: ProcessNetworkRate] = [:]
        for (pid, current) in snapshot {
            let prior = previous[pid] ?? (received: 0, sent: 0)
            let deltaIn = current.received >= prior.received ? current.received - prior.received : 0
            let deltaOut = current.sent >= prior.sent ? current.sent - prior.sent : 0
            guard deltaIn > 0 || deltaOut > 0 else { continue }
            nextRates[pid] = ProcessNetworkRate(
                receivedBytesPerSecond: Double(deltaIn) / safeElapsed,
                sentBytesPerSecond: Double(deltaOut) / safeElapsed
            )
        }

        baselineCounters = snapshot
        baselineTimestamp = now
        latestRates = nextRates
        hasPublishedFrame = true
        publishedSequence &+= 1
        let currentSequence = publishedSequence
        var readyCallbacks: [@Sendable () -> Void] = []
        for (id, entry) in frameWaiters where currentSequence >= entry.minSequence {
            readyCallbacks.append(entry.callback)
            frameWaiters.removeValue(forKey: id)
        }
        return (readyCallbacks, nil)
    }

    private func scheduleInitialProbe(for expectedGeneration: UInt64) {
        probeQueue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            self?.runInitialProbe(expectedGeneration: expectedGeneration)
        }
    }

    private func runInitialProbe(expectedGeneration: UInt64) {
        lock.lock()
        let active = task != nil && generation == expectedGeneration && !hasPublishedFrame
        lock.unlock()
        guard active else { return }

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = Self.singleShotArguments
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = FileHandle.nullDevice

        lock.lock()
        guard task != nil, generation == expectedGeneration, !hasPublishedFrame else {
            lock.unlock()
            try? masterHandle.close()
            try? slaveHandle.close()
            return
        }
        probeTask = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.lock()
            if probeTask === process { probeTask = nil }
            lock.unlock()
            try? masterHandle.close()
            try? slaveHandle.close()
            return
        }

        // Keep slaveHandle open until nettop exits and master buffer is drained;
        // closing the slave PTY early on Darwin revokes unread master output with EIO.
        var output = Data()
        var scratch = [UInt8](repeating: 0, count: 16_384)
        var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(600))
        while ContinuousClock.now < deadline {
            let ready = Darwin.poll(&pfd, 1, 15)
            if ready > 0, (pfd.revents & Int16(POLLIN)) != 0 {
                let count = Darwin.read(master, &scratch, scratch.count)
                if count > 0 {
                    output.append(scratch, count: count)
                } else {
                    break
                }
            } else if !process.isRunning {
                // Process exited and no POLLIN left in kernel PTY queue.
                break
            }
        }
        process.waitUntilExit()
        while Darwin.poll(&pfd, 1, 0) > 0, (pfd.revents & Int16(POLLIN)) != 0 {
            let count = Darwin.read(master, &scratch, scratch.count)
            if count > 0 {
                output.append(scratch, count: count)
            } else {
                break
            }
        }
        try? slaveHandle.close()
        try? masterHandle.close()

        let text = String(decoding: output, as: UTF8.self)
        let counters = Self.parseCounters(text)
        guard !counters.isEmpty else { return }

        var callbacks: [@Sendable () -> Void] = []
        lock.lock()
        if probeTask === process { probeTask = nil }
        if task != nil, generation == expectedGeneration, !hasPublishedFrame {
            callbacks = applyCumulativeSnapshotLocked(counters, at: ContinuousClock.now).waiters
        }
        lock.unlock()

        for callback in callbacks {
            callback()
        }
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Deterministic test hook for cumulative diffing without spawning `/usr/bin/nettop`.
    func ingestSnapshotForTesting(
        _ counters: [pid_t: (received: UInt64, sent: UInt64)],
        elapsedSeconds: Double
    ) {
        lock.lock()
        let callbacks = applyCumulativeSnapshotLocked(
            counters,
            at: ContinuousClock.now,
            overrideElapsedSeconds: elapsedSeconds
        ).waiters
        lock.unlock()
        for callback in callbacks {
            callback()
        }
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

    /// Parse a multi-line CSV snapshot into cumulative per-PID byte counters.
    nonisolated static func parseCounters(_ output: String) -> [pid_t: (received: UInt64, sent: UInt64)] {
        var counters: [pid_t: (received: UInt64, sent: UInt64)] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = String(line)
            if isHeader(trimmed) { continue }
            guard let parsed = parseLine(trimmed) else { continue }
            counters[parsed.pid] = (parsed.received, parsed.sent)
        }
        return counters
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
