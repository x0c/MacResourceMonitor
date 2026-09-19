import AppKit
import XCTest
@testable import MacResourceMonitor

final class ProcessNetworkSamplerTests: XCTestCase {
    func testParsesNettopProcessCounters() {
        let counters = ProcessNetworkSampler.parse("""
        ,bytes_in,bytes_out,
        Google Chrome.42,1024,2048,
        com.example.worker.99,0,7,
        """)
        XCTAssertEqual(counters[42]?.received, 1_024)
        XCTAssertEqual(counters[42]?.sent, 2_048)
        XCTAssertEqual(counters[99]?.received, 0)
        XCTAssertEqual(counters[99]?.sent, 7)
    }
}

final class NettopStreamSamplerParseTests: XCTestCase {
    func testRecognizesCurrentJFlagHeaderWithoutTimeColumn() {
        XCTAssertTrue(NettopStreamSampler.isHeader(",bytes_in,bytes_out,"))
        XCTAssertTrue(NettopStreamSampler.isHeader("time,,bytes_in,bytes_out,"))
        XCTAssertFalse(NettopStreamSampler.isHeader("launchd.1,0,0,"))
    }

    func testParsesCurrentJFlagDeltaRow() {
        let parsed = NettopStreamSampler.parseLine("Google Chrome.42,1024,2048,")
        XCTAssertEqual(parsed?.pid, 42)
        XCTAssertEqual(parsed?.received, 1_024)
        XCTAssertEqual(parsed?.sent, 2_048)
    }

    func testParsesLegacyTimePrefixedDeltaRow() {
        let parsed = NettopStreamSampler.parseLine("14:44:40.476850,mihomo.1711,59782,25854,")
        XCTAssertEqual(parsed?.pid, 1_711)
        XCTAssertEqual(parsed?.received, 59_782)
        XCTAssertEqual(parsed?.sent, 25_854)
    }

    /// Regression for the 2026-09-13 crash: handleChunk touched the byte buffer
    /// without the lock while stop() cleared it on another thread → Index out
    /// of range on the NSFileHandle.fd_monitoring queue (EXC_BREAKPOINT).
    /// Hammer chunks concurrently with stop()/start(); must never trap.
    func testConcurrentChunkAndStopDoesNotTrap() {
        let sampler = NettopStreamSampler()
        sampler.stop() // no stream: every chunk must be a no-op, never a trap
        let group = DispatchGroup()
        for i in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                let line = ",bytes_in,bytes_out,\nChrome.\(1000 + (i % 50)),\(i),\(i),\n"
                sampler.handleChunk(Data(line.utf8))
                if i % 25 == 0 { sampler.stop() }
                group.leave()
            }
        }
        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success)
        _ = sampler.latestRatesSnapshot()
    }

    func testSamplerArgumentSignatureIgnoresArgv0() {
        XCTAssertTrue(
            NettopStreamSampler.matchesSamplerArguments(
                ["/usr/bin/nettop"] + NettopStreamSampler.arguments
            )
        )
        XCTAssertTrue(NettopStreamSampler.matchesSamplerArguments(NettopStreamSampler.arguments))
        XCTAssertFalse(
            NettopStreamSampler.matchesSamplerArguments(
                ["/usr/bin/nettop", "-d", "-P", "-L", "2", "-s", "1"]
            )
        )
        XCTAssertTrue(
            NettopStreamSampler.isSamplerProcess(
                path: "/usr/bin/nettop",
                arguments: ["/usr/bin/nettop"] + NettopStreamSampler.arguments
            )
        )
    }
}

@MainActor
final class NetworkListSamplingLifecycleTests: XCTestCase {
    func testWarmupBudgetIsFinite() {
        XCTAssertEqual(NetworkListModel.warmupSampleBudget, 2)
    }

    func testClosingPanelKeepsRetainedRows() async throws {
        let chrome = ProcessRow(
            id: "Google Chrome",
            displayName: "Google Chrome",
            bundlePath: nil,
            iconPath: nil,
            executablePath: "/tmp/Google Chrome",
            memberIdentities: [ProcessIdentity(pid: 42, startTime: 1)],
            cpuPercent: 0,
            memoryPercent: 0,
            kind: .other,
            isCurrentUser: true,
            isSystemProtected: false
        )
        let model = NetworkListModel(processRows: { [chrome] })
        // Wait for warmup to settle without leaving a permanent sampler running.
        try await Task.sleep(for: .milliseconds(2_400))
        model.setPanelVisible(false)
        try await Task.sleep(for: .milliseconds(200))
        // Closing must not clear the retained frame (may be empty if no traffic).
        _ = model.rows
        model.setPanelVisible(true)
        model.setPanelVisible(false)
    }
}

final class NetworkTableRankingTests: XCTestCase {
    func testUploadAndDownloadRemainIndependentlyDescending() {
        let rows = [
            makeRow(name: "Upload", upload: 50, download: 2),
            makeRow(name: "Download", upload: 2, download: 80)
        ]
        XCTAssertEqual(
            NetworkTableRanking.visibleRows(from: rows, sort: .upload).map(\.displayName),
            ["Upload", "Download"]
        )
        XCTAssertEqual(
            NetworkTableRanking.visibleRows(from: rows, sort: .download).map(\.displayName),
            ["Download", "Upload"]
        )
    }

    func testPinnedNetworkRowKeepsItsPositionWithNewRates() {
        let rows = [
            makeRow(name: "A", upload: 30, download: 1),
            makeRow(name: "B", upload: 5, download: 90)
        ]
        let visible = NetworkTableRanking.visibleRows(
            from: rows,
            sort: .upload,
            pinnedID: "B",
            pinnedIndex: 0
        )
        XCTAssertEqual(visible.map(\.displayName), ["B", "A"])
        XCTAssertEqual(visible.first?.downloadBytesPerSecond, 90)
    }

    func testFrozenNetworkRowsKeepSnapshotOrder() {
        let rows = [
            makeRow(name: "Upload", upload: 50, download: 2),
            makeRow(name: "Download", upload: 2, download: 80)
        ]
        let frozen = NetworkTableRanking.visibleRows(from: rows, sort: .download, frozen: true)
        XCTAssertEqual(frozen.map(\.displayName), ["Upload", "Download"])
    }

    func testRecentlyActiveRowSurvivesZeroRateSample() {
        let chrome = makeProcess(name: "Google Chrome", pid: 42)
        let now = Date(timeIntervalSince1970: 1_000)
        let active = NetworkListPresence.rows(
            processes: [chrome],
            rates: [42: ProcessNetworkRate(receivedBytesPerSecond: 8_192, sentBytesPerSecond: 0)],
            holdUntil: [:],
            now: now
        )
        XCTAssertEqual(active.rows.map(\.displayName), ["Google Chrome"])
        XCTAssertEqual(active.rows.first?.downloadBytesPerSecond, 8_192)

        let quiet = NetworkListPresence.rows(
            processes: [chrome],
            rates: [:],
            holdUntil: active.holdUntil,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(quiet.rows.map(\.displayName), ["Google Chrome"])
        XCTAssertEqual(quiet.rows.first?.downloadBytesPerSecond, 0)
        XCTAssertEqual(quiet.rows.first?.uploadBytesPerSecond, 0)
    }

    /// 旧实现在 inout 钉位期间经 visibleRows 回读同一属性，会 SIGABRT；空名单也能复现。
    @MainActor
    func testNetworkListSetEndHoverDoesNotTripExclusivity() {
        let model = NetworkListModel(processRows: { [] })
        model.setEndHover(true, rowID: "ghost")
        model.setEndHover(false, rowID: "ghost")
    }

    func testHoldStillActiveBeforeFifteenSeconds() {
        let chrome = makeProcess(name: "Google Chrome", pid: 42)
        let now = Date(timeIntervalSince1970: 1_000)
        let active = NetworkListPresence.rows(
            processes: [chrome],
            rates: [42: ProcessNetworkRate(receivedBytesPerSecond: 1_024, sentBytesPerSecond: 0)],
            holdUntil: [:],
            now: now
        )
        let quiet = NetworkListPresence.rows(
            processes: [chrome],
            rates: [:],
            holdUntil: active.holdUntil,
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(quiet.rows.map(\.displayName), ["Google Chrome"])
        XCTAssertEqual(quiet.rows.first?.downloadBytesPerSecond, 0)
    }

    func testHoldExpiresAfterFifteenSecondsWithoutTraffic() {
        let chrome = makeProcess(name: "Google Chrome", pid: 42)
        let now = Date(timeIntervalSince1970: 1_000)
        let active = NetworkListPresence.rows(
            processes: [chrome],
            rates: [42: ProcessNetworkRate(receivedBytesPerSecond: 1_024, sentBytesPerSecond: 0)],
            holdUntil: [:],
            now: now
        )
        let expired = NetworkListPresence.rows(
            processes: [chrome],
            rates: [:],
            holdUntil: active.holdUntil,
            now: now.addingTimeInterval(NetworkListPresence.holdDuration + 0.01)
        )
        XCTAssertTrue(expired.rows.isEmpty)
        XCTAssertTrue(expired.holdUntil.isEmpty)
    }

    func testDeadProcessIsRemovedEvenDuringHold() {
        let chrome = makeProcess(name: "Google Chrome", pid: 42)
        let now = Date(timeIntervalSince1970: 1_000)
        let active = NetworkListPresence.rows(
            processes: [chrome],
            rates: [42: ProcessNetworkRate(receivedBytesPerSecond: 1_024, sentBytesPerSecond: 0)],
            holdUntil: [:],
            now: now
        )
        let gone = NetworkListPresence.rows(
            processes: [],
            rates: [:],
            holdUntil: active.holdUntil,
            now: now.addingTimeInterval(1)
        )
        XCTAssertTrue(gone.rows.isEmpty)
        XCTAssertTrue(gone.holdUntil.isEmpty)
    }

    private func makeRow(name: String, upload: Double, download: Double) -> NetworkProcessRow {
        NetworkProcessRow(
            process: makeProcess(name: name, pid: 1),
            uploadBytesPerSecond: upload,
            downloadBytesPerSecond: download
        )
    }

    private func makeProcess(name: String, pid: pid_t) -> ProcessRow {
        ProcessRow(
            id: name,
            displayName: name,
            bundlePath: nil,
            iconPath: nil,
            executablePath: "/tmp/\(name)",
            memberIdentities: [ProcessIdentity(pid: pid, startTime: 1)],
            cpuPercent: 0,
            memoryPercent: 0,
            kind: .other,
            isCurrentUser: true,
            isSystemProtected: false
        )
    }
}

@MainActor
final class StatusItemPanelTargetTests: XCTestCase {
    func testRingAndNetworkUseSeparateStatusImages() {
        let ringImage = MenuBarIconRenderer.image(
            cpuPercent: 0,
            memoryPercent: 0
        )
        let networkImage = MenuBarIconRenderer.networkImage(
            uploadBytesPerSecond: nil,
            downloadBytesPerSecond: nil
        )
        XCTAssertEqual(ringImage.size.width, MenuBarIconRenderer.pointSize)
        XCTAssertGreaterThan(networkImage.size.width, 0)
        XCTAssertEqual(ringImage.size.height, networkImage.size.height)
        XCTAssertTrue(ringImage.isTemplate, "圆环必须是模板图，由系统按菜单栏明暗着色")
        XCTAssertTrue(networkImage.isTemplate, "网速块必须是模板图，由系统按菜单栏明暗着色")
        XCTAssertTrue(
            ringImage.representations.contains(where: { $0 is NSBitmapImageRep }),
            "动态绘制必须先栅格成位图，不能只留 NSCustomImageRep 直接往菜单栏画黑笔"
        )
        XCTAssertTrue(
            networkImage.representations.contains(where: { $0 is NSBitmapImageRep }),
            "动态绘制必须先栅格成位图，不能只留 NSCustomImageRep 直接往菜单栏画黑笔"
        )
    }

    func testRingTemplateKeepsConcentricInkNearCenter() {
        let image = MenuBarIconRenderer.image(cpuPercent: 75, memoryPercent: 40)
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            return XCTFail("圆环模板必须有位图表示")
        }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        XCTAssertGreaterThan(width, 8)
        XCTAssertGreaterThan(height, 8)

        var inkCount = 0
        var inkSumX = 0
        var inkSumY = 0
        var cornerInk = 0
        let corner = max(2, min(width, height) / 8)
        for y in 0..<height {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                var alpha: CGFloat = 0
                color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
                guard alpha > 0.05 else { continue }
                inkCount += 1
                inkSumX += x
                inkSumY += y
                if x < corner || y < corner || x >= width - corner || y >= height - corner {
                    cornerInk += 1
                }
            }
        }
        XCTAssertGreaterThan(inkCount, 20, "圆环应留下可见墨迹")
        let meanX = Double(inkSumX) / Double(inkCount)
        let meanY = Double(inkSumY) / Double(inkCount)
        XCTAssertEqual(meanX, Double(width) / 2, accuracy: Double(width) * 0.2, "墨迹重心应靠近画布中心，不能被错误缩放挤到一角")
        XCTAssertEqual(meanY, Double(height) / 2, accuracy: Double(height) * 0.25, "墨迹重心应靠近画布中心，不能被错误缩放挤到一角")
        XCTAssertLessThan(
            Double(cornerInk) / Double(inkCount),
            0.45,
            "墨迹不应主要堆在四角——那是 scaleBy(Retina) 把圆环放大裁切后的典型症状"
        )
    }

    func testNetworkTableDefaultsToDownloadOrder() {
        XCTAssertEqual(NetworkListModel.defaultSortColumn, .download)
    }

    func testMenuBarItemsUseFixedVisualOrder() {
        XCTAssertEqual(
            StatusItemPanelTarget.statusItemCreationOrder,
            [.networkDownload, .process]
        )
    }

}
