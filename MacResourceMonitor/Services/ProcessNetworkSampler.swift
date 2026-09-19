import Foundation

/// Per-process network rates from a long-lived `nettop` stream (mac-stats / iStat pattern).
/// Session starts while the network table is visible or during startup warmup, then stops.
actor ProcessNetworkSampler {
    private nonisolated(unsafe) let stream = NettopStreamSampler()

    func prepare() {
        stream.start()
    }

    func shutdown() {
        stream.stop()
    }

    nonisolated func stopSync() {
        stream.stop()
    }

    func resetBaseline() {
        // nettop `-d` emits self-contained per-second deltas; no client-side baseline.
    }

    /// True once the stream has published at least one real delta frame (not the baseline).
    var hasFrame: Bool { stream.hasFrame }

    func sample() async -> [pid_t: ProcessNetworkRate] {
        prepare()
        return stream.latestRatesSnapshot()
    }

    /// Wait briefly for the first delta frame after start (baseline + one second).
    func waitForFirstFrame(timeoutSeconds: Double = 2.5) async {
        prepare()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if stream.hasFrame { return }
            try? await Task.sleep(for: .milliseconds(100))
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
}
