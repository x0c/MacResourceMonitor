import SwiftUI
import XCTest
@testable import MacResourceMonitor

final class ProcessTableRankingTests: XCTestCase {
    func testCPUSortPutsHighestCPUFirst() {
        let rows = [
            makeRow(name: "LowCPU", cpu: 1, memory: 40),
            makeRow(name: "HighCPU", cpu: 20, memory: 2)
        ]
        let visible = ProcessTableRanking.visibleRows(from: rows, sort: .cpu)
        XCTAssertEqual(visible.map(\.displayName), ["HighCPU", "LowCPU"])
    }

    func testMemorySortPutsHighestMemoryFirst() {
        let rows = [
            makeRow(name: "LowCPU", cpu: 1, memory: 40),
            makeRow(name: "HighCPU", cpu: 20, memory: 2)
        ]
        let visible = ProcessTableRanking.visibleRows(from: rows, sort: .memory)
        XCTAssertEqual(visible.map(\.displayName), ["LowCPU", "HighCPU"])
    }

    func testSortNeverAscends() {
        let rows = [
            makeRow(name: "A", cpu: 3, memory: 1),
            makeRow(name: "B", cpu: 9, memory: 8),
            makeRow(name: "C", cpu: 6, memory: 4)
        ]
        XCTAssertEqual(
            ProcessTableRanking.visibleRows(from: rows, sort: .cpu).map(\.cpuPercent),
            [9, 6, 3]
        )
        XCTAssertEqual(
            ProcessTableRanking.visibleRows(from: rows, sort: .memory).map(\.memoryPercent),
            [8, 4, 1]
        )
    }

    func testIdleRowsStayHiddenWhenEnoughBusy() {
        var rows: [ProcessRow] = (0..<8).map { index in
            makeRow(name: "Busy\(index)", cpu: Double(8 - index), memory: 1)
        }
        rows.append(makeRow(name: "Idle", cpu: 0, memory: 0))
        let visible = ProcessTableRanking.visibleRows(from: rows, sort: .cpu)
        XCTAssertEqual(visible.count, 8)
        XCTAssertFalse(visible.contains { $0.displayName == "Idle" })
    }

    func testFrozenKeepsSnapshotOrderWithoutResorting() {
        let rows = [
            makeRow(name: "LowCPU", cpu: 1, memory: 40),
            makeRow(name: "HighCPU", cpu: 20, memory: 2)
        ]
        let frozen = ProcessTableRanking.visibleRows(from: rows, sort: .cpu, frozen: true)
        XCTAssertEqual(frozen.map(\.displayName), ["LowCPU", "HighCPU"])
    }

    func testFrozenMergeKeepsOrderAndRefreshesNumbers() {
        let existing = [
            makeRow(name: "A", cpu: 1, memory: 1),
            makeRow(name: "B", cpu: 2, memory: 2),
            makeRow(name: "C", cpu: 3, memory: 3)
        ]
        let fresh = [
            makeRow(name: "C", cpu: 30, memory: 30),
            makeRow(name: "New", cpu: 99, memory: 99),
            makeRow(name: "A", cpu: 10, memory: 10)
        ]
        let merged = TableRowPinning.mergePreservingOrder(existing: existing, fresh: fresh)
        XCTAssertEqual(merged.map(\.displayName), ["A", "C"])
        XCTAssertEqual(merged.map(\.cpuPercent), [10, 30])
    }

    func testPercentTextUsesOneDecimal() {
        XCTAssertEqual(ProcessTableRanking.percentText(88.8), "88.8%")
        XCTAssertEqual(ProcessTableRanking.percentText(68.8), "68.8%")
    }

    func testPinnedRowStaysAtIndexWhenRankingWouldMoveIt() {
        let rows = [
            makeRow(name: "A", cpu: 15, memory: 1),
            makeRow(name: "B", cpu: 30, memory: 1),
            makeRow(name: "C", cpu: 5, memory: 1)
        ]
        let visible = ProcessTableRanking.visibleRows(
            from: rows,
            sort: .cpu,
            pinnedID: "B",
            pinnedIndex: 1
        )
        XCTAssertEqual(visible.map(\.displayName), ["A", "B", "C"])
        XCTAssertEqual(visible[1].cpuPercent, 30)
    }

    func testPinnedRowKeepsUpdatedNumbers() {
        let rows = [
            makeRow(name: "A", cpu: 20, memory: 1),
            makeRow(name: "B", cpu: 8, memory: 7)
        ]
        let visible = ProcessTableRanking.visibleRows(
            from: rows,
            sort: .cpu,
            pinnedID: "B",
            pinnedIndex: 0
        )
        XCTAssertEqual(visible.map(\.displayName), ["B", "A"])
        XCTAssertEqual(visible[0].cpuPercent, 8)
        XCTAssertEqual(visible[0].memoryPercent, 7)
    }

    func testMissingPinnedRowDoesNotLeaveGhost() {
        let rows = [
            makeRow(name: "A", cpu: 20, memory: 1),
            makeRow(name: "C", cpu: 5, memory: 1)
        ]
        let visible = ProcessTableRanking.visibleRows(
            from: rows,
            sort: .cpu,
            pinnedID: "B",
            pinnedIndex: 1
        )
        XCTAssertEqual(visible.map(\.displayName), ["A", "C"])
    }

    func testPinnedIdleRowStaysVisible() {
        var rows: [ProcessRow] = (0..<8).map { index in
            makeRow(name: "Busy\(index)", cpu: Double(8 - index), memory: 1)
        }
        rows.append(makeRow(name: "Target", cpu: 0, memory: 0))
        let visible = ProcessTableRanking.visibleRows(
            from: rows,
            sort: .cpu,
            pinnedID: "Target",
            pinnedIndex: 0
        )
        XCTAssertEqual(visible.first?.displayName, "Target")
        XCTAssertEqual(visible.first?.cpuPercent, 0)
        XCTAssertTrue(visible.contains { $0.displayName == "Busy0" })
    }

    @MainActor
    func testPinnedEndHoverUsesPrecomputedIndex() {
        var pinnedRowID: String?
        var pinnedIndex: Int?
        var unpinTask: Task<Void, Never>?
        PinnedEndHover.apply(
            hovering: true,
            rowID: "B",
            pinnedRowID: &pinnedRowID,
            pinnedIndex: &pinnedIndex,
            unpinTask: &unpinTask,
            visibleIndex: 1,
            clearPin: {
                pinnedRowID = nil
                pinnedIndex = nil
            },
            currentPinnedID: { pinnedRowID }
        )
        XCTAssertEqual(pinnedRowID, "B")
        XCTAssertEqual(pinnedIndex, 1)

        PinnedEndHover.apply(
            hovering: true,
            rowID: "B",
            pinnedRowID: &pinnedRowID,
            pinnedIndex: &pinnedIndex,
            unpinTask: &unpinTask,
            visibleIndex: 99,
            clearPin: {
                pinnedRowID = nil
                pinnedIndex = nil
            },
            currentPinnedID: { pinnedRowID }
        )
        XCTAssertEqual(pinnedIndex, 1, "同一行再次悬停不得改写已钉索引")
    }

    /// 旧实现在 inout 钉位期间经 visibleRows 回读同一属性，会 SIGABRT；空名单也能复现。
    @MainActor
    func testProcessListSetEndHoverDoesNotTripExclusivity() {
        let model = ProcessListModel()
        defer { model.stop() }
        model.setEndHover(true, rowID: "ghost")
        model.setEndHover(false, rowID: "ghost")
    }

    @MainActor
    func testSelectSortTurnsOffFreeze() {
        let model = ProcessListModel()
        defer { model.stop() }
        model.listFrozen = true
        model.selectSort(.memory)
        XCTAssertFalse(model.listFrozen)
        XCTAssertEqual(model.sortColumn, .memory)
    }

    private func makeRow(name: String, cpu: Double, memory: Double) -> ProcessRow {
        ProcessRow(
            id: name,
            displayName: name,
            bundlePath: nil,
            iconPath: nil,
            memberIdentities: [ProcessIdentity(pid: 1, startTime: 1)],
            cpuPercent: cpu,
            memoryPercent: memory,
            kind: .other,
            isCurrentUser: true,
            isSystemProtected: false
        )
    }
}

final class ProcessNamePresentationTests: XCTestCase {
    func testHumanNamesKeepTheStart() {
        XCTAssertEqual(ProcessNamePresentation.truncationMode(for: "Google Chrome"), .tail)
        XCTAssertEqual(ProcessNamePresentation.truncationMode(for: "Activity Monitor"), .tail)
        XCTAssertEqual(ProcessNamePresentation.truncationMode(for: "IntelliJ IDEA"), .tail)
        XCTAssertEqual(ProcessNamePresentation.truncationMode(for: "Cursor Agent"), .tail)
        XCTAssertEqual(ProcessNamePresentation.truncationMode(for: "node"), .tail)
    }

    func testReverseDNSNamesKeepTheEnd() {
        XCTAssertEqual(ProcessNamePresentation.truncationMode(for: "com.apple.TimeMachine"), .head)
        XCTAssertEqual(ProcessNamePresentation.truncationMode(for: "com.apple.backupd"), .head)
        XCTAssertEqual(ProcessNamePresentation.truncationMode(for: "io.sentry.Sentry"), .head)
    }
}

final class ListFrozenPreferenceTests: XCTestCase {
    func testLegacyRefreshOffMigratesToFrozenOn() {
        let defaults = UserDefaults(suiteName: "mac-resource-monitor-freeze-migrate-\(UUID().uuidString)")!
        defaults.set(false, forKey: AppPreferences.legacyRefreshEnabledKey)
        let frozen = AppPreferences.readListFrozen(
            defaults: defaults,
            key: AppPreferences.listFrozenKey,
            legacyKey: AppPreferences.legacyRefreshEnabledKey,
            defaultValue: false
        )
        XCTAssertTrue(frozen)
        XCTAssertTrue(defaults.bool(forKey: AppPreferences.listFrozenKey))
        XCTAssertNil(defaults.object(forKey: AppPreferences.legacyRefreshEnabledKey))
    }
}
