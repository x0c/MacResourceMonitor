
import XCTest
@testable import MacResourceMonitor

final class CPUSampleTests: XCTestCase {
    func testSystemLoadUsesBusyDeltaOverAllCoreTicks() {
        let previous = SystemCPULoad(busyTicks: 100, totalTicks: 1_000)
        let current = SystemCPULoad(busyTicks: 220, totalTicks: 1_200)
        // 120 busy ticks of 200 total ticks across every core.
        XCTAssertEqual(current.percent(since: previous) ?? -1, 60, accuracy: 0.0001)
    }

    func testSystemLoadBreakdownSplitsUserAndSystemTicks() {
        let previous = SystemCPULoad(userTicks: 300, systemTicks: 100, totalTicks: 1_000)
        let current = SystemCPULoad(userTicks: 390, systemTicks: 130, totalTicks: 1_200)
        let breakdown = current.breakdown(since: previous)
        XCTAssertEqual(breakdown?.totalPercent ?? -1, 60, accuracy: 0.0001)
        XCTAssertEqual(breakdown?.systemPercent ?? -1, 15, accuracy: 0.0001)
    }

    func testKernelTaskEstimateCapsAtUnattributedSystemSpace() {
        // Host busy 80% (20% system, 60% user), surviving rows cover 55% (8% owned system):
        // total gap is 25%, but only 12% is unattributed system-space CPU; the other 13%
        // belongs to exited/first-frame user builds and must not inflate kernel_task.
        let breakdown = SystemCPULoad.Breakdown(totalPercent: 80, systemPercent: 20)
        let kernel = ProcessSampler.kernelTaskCPUPercent(
            instantHost: breakdown,
            attributedTotal: 55,
            ownedSystem: 8
        )
        XCTAssertEqual(kernel ?? -1, 12, accuracy: 0.0001)

        // When unattributed system CPU is negligible (< 0.5%), no kernel_task row is emitted.
        let tiny = ProcessSampler.kernelTaskCPUPercent(
            instantHost: SystemCPULoad.Breakdown(totalPercent: 40, systemPercent: 6),
            attributedTotal: 25,
            ownedSystem: 5.8
        )
        XCTAssertNil(tiny)
    }

    func testSystemLoadClampsAndRejectsInvalidDeltas() {
        let previous = SystemCPULoad(busyTicks: 100, totalTicks: 1_000)
        XCTAssertNil(SystemCPULoad(busyTicks: 90, totalTicks: 1_000).percent(since: previous))
        XCTAssertNil(SystemCPULoad(busyTicks: 100, totalTicks: 900).percent(since: previous))
        XCTAssertNil(SystemCPULoad(busyTicks: 100, totalTicks: 1_000).percent(since: previous))
        XCTAssertEqual(
            SystemCPULoad(busyTicks: 1_100, totalTicks: 2_000).percent(since: previous) ?? -1,
            100,
            accuracy: 0.0001
        )
    }

    func testSystemLoadReadReturnsMachineTicks() {
        let load = SystemCPULoad.read()
        XCTAssertNotNil(load)
        XCTAssertGreaterThan(load?.totalTicks ?? 0, 0)
        XCTAssertLessThanOrEqual(load?.busyTicks ?? 1, load?.totalTicks ?? 0)
    }

    func testForeignParseReadsMinutesAndHoursStyleClocks() {
        let samples = ForeignProcessCPU.parse(
            """
                1     0  27:31.96
              432    88 356:17.43
            98730   501   0:20.40
            """
        )
        XCTAssertEqual(samples[1]?.seconds ?? 0, 27 * 60 + 31.96, accuracy: 0.001)
        XCTAssertEqual(samples[432]?.uid, 88)
        XCTAssertEqual(samples[432]?.seconds ?? 0, 356 * 60 + 17.43, accuracy: 0.001)
        XCTAssertEqual(samples[98730]?.seconds ?? 0, 20.40, accuracy: 0.001)
    }

    func testForeignParseIgnoresJunkLines() {
        let samples = ForeignProcessCPU.parse(
            """
            not a process
              77   501   1:02.50
              88
            """
        )
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[77]?.seconds ?? 0, 62.50, accuracy: 0.001)
    }

    func testForeignReadsEveryProcessWithPS() async {
        let samples = await ForeignProcessCPU.read()
        XCTAssertNotNil(samples)
        XCTAssertGreaterThan(samples?.count ?? 0, 10)
        // WindowServer runs as a non-current user on every Mac; its cumulative time must
        // be readable or the panel still hides the biggest UI hog.
        XCTAssertTrue(samples?.values.contains { $0.uid != getuid() && $0.seconds > 0 } == true)
    }
}
