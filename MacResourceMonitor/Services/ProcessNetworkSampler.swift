import Foundation

nonisolated struct ProcessNetworkSample: Sendable {
    let hasFrame: Bool
    let sequence: UInt64
    let rates: [pid_t: ProcessNetworkRate]
}

/// Per-process network rates from a long-lived cumulative `nettop` stream plus fast initial probe.
/// Session starts while the network table is visible or during startup warmup, then stops.
actor ProcessNetworkSampler {
    private let stream = NettopStreamSampler()

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
        // Baseline is initialized per stream session inside NettopStreamSampler.
    }

    /// True once the stream has published at least one real delta frame (not the baseline).
    var hasFrame: Bool { stream.hasFrame }

    func sampleSnapshot() async -> ProcessNetworkSample {
        prepare()
        let snapshot = stream.latestSampleSnapshot()
        return ProcessNetworkSample(
            hasFrame: snapshot.hasFrame,
            sequence: snapshot.sequence,
            rates: snapshot.rates
        )
    }

    func sample() async -> [pid_t: ProcessNetworkRate] {
        await sampleSnapshot().rates
    }

    /// Wait event-driven for the first real delta frame after start (~250ms via initial probe).
    func waitForFirstFrame(timeoutSeconds: Double = 1.5) async {
        guard !Task.isCancelled else { return }
        await stream.waitForFirstFrame(timeoutSeconds: timeoutSeconds)
    }

    func waitForNextFrame(after sequence: UInt64, timeoutSeconds: Double = 1.25) async {
        guard !Task.isCancelled else { return }
        await stream.waitForNextFrame(after: sequence, timeoutSeconds: timeoutSeconds)
    }

    nonisolated static func parse(_ output: String) -> [pid_t: (received: UInt64, sent: UInt64)] {
        NettopStreamSampler.parseCounters(output)
    }
}
