import XCTest
@testable import MacResourceMonitor

final class NetworkSpeedMonitorTests: XCTestCase {
    func testParsesCurrentDefaultRouteInterface() {
        let route = """
        route to: default
        interface: en0
        flags: <UP,GATEWAY,DONE,STATIC>
        """
        XCTAssertEqual(NetworkSpeedMonitor.defaultRouteInterfaceName(from: route), "en0")
    }

    func testMissingDefaultRouteHasNoInterface() {
        XCTAssertNil(NetworkSpeedMonitor.defaultRouteInterfaceName(from: "route to: default\n"))
    }

    func testUsesCompleteRateUnits() {
        XCTAssertEqual(NetworkRateFormatter.text(for: 512), "<1 KB/s")
        XCTAssertEqual(NetworkRateFormatter.text(for: 1_024 * 1_024 * 8.4), "8 MB/s")
        XCTAssertEqual(NetworkRateFormatter.text(for: 1_024 * 1_024 * 1_024 * 2), "2 GB/s")
    }

    func testRateValuesStayWithinThreeDigits() {
        XCTAssertEqual(NetworkRateFormatter.text(for: 999 * 1_024), "999 KB/s")
        // 再高一档：不足 1 MB/GB 时按既有规则显示 <1，而不是四位 KB/MB。
        XCTAssertEqual(NetworkRateFormatter.text(for: 1_000 * 1_024), "<1 MB/s")
        XCTAssertEqual(NetworkRateFormatter.text(for: 999 * 1_024 * 1_024), "999 MB/s")
        XCTAssertEqual(NetworkRateFormatter.text(for: 1_000 * 1_024 * 1_024), "<1 GB/s")
        XCTAssertEqual(NetworkRateFormatter.text(for: 1_024 * 1_024), "1 MB/s")
    }

    func testPairsDirectionsUnderTheirLargestUnit() {
        let pair = NetworkRateFormatter.pair(
            uploadBytesPerSecond: 349 * 1_024,
            downloadBytesPerSecond: 5 * 1_024 * 1_024
        )
        XCTAssertEqual(pair.upload, "<1")
        XCTAssertEqual(pair.download, "5")
        XCTAssertEqual(pair.unit, "MB/s")
    }

    func testMissingSampleUsesDashInsteadOfStaleSpeed() {
        XCTAssertEqual(NetworkRateFormatter.text(for: nil), "—")
        XCTAssertEqual(
            NetworkRateFormatter.parts(for: nil),
            NetworkRateTextParts(value: "—", unit: nil)
        )
    }

    func testTablePartsKeepValueAndUnitSeparate() {
        XCTAssertEqual(
            NetworkRateFormatter.parts(for: 28 * 1_024),
            NetworkRateTextParts(value: "28", unit: "KB/s")
        )
        XCTAssertEqual(
            NetworkRateFormatter.parts(for: 512),
            NetworkRateTextParts(value: "<1", unit: "KB/s")
        )
    }

    @MainActor
    func testFasterDirectionReceivesTextEmphasis() {
        XCTAssertEqual(
            NetworkSpeedEmphasis.resolve(
                uploadBytesPerSecond: 8_000,
                downloadBytesPerSecond: 2_000
            ),
            .upload
        )
        XCTAssertEqual(
            NetworkSpeedEmphasis.resolve(
                uploadBytesPerSecond: 2_000,
                downloadBytesPerSecond: 8_000
            ),
            .download
        )
    }

    @MainActor
    func testEqualOrMissingRatesRemainVisuallyBalanced() {
        XCTAssertEqual(
            NetworkSpeedEmphasis.resolve(
                uploadBytesPerSecond: 2_000,
                downloadBytesPerSecond: 2_000
            ),
            .balanced
        )
        XCTAssertEqual(
            NetworkSpeedEmphasis.resolve(
                uploadBytesPerSecond: nil,
                downloadBytesPerSecond: 2_000
            ),
            .balanced
        )
    }

    @MainActor
    func testStatusItemWidthRemainsStableAcrossRefreshValues() {
        let images = [
            MenuBarIconRenderer.networkImage(
                uploadBytesPerSecond: 0,
                downloadBytesPerSecond: 3 * 1_024
            ),
            MenuBarIconRenderer.networkImage(
                uploadBytesPerSecond: 999 * 1_024,
                downloadBytesPerSecond: 999 * 1_024
            ),
            MenuBarIconRenderer.networkImage(
                uploadBytesPerSecond: 2 * 1_024 * 1_024 * 1_024,
                downloadBytesPerSecond: 0
            ),
            MenuBarIconRenderer.networkImage(
                uploadBytesPerSecond: nil,
                downloadBytesPerSecond: nil
            )
        ]

        XCTAssertEqual(images[0].size.width, MenuBarIconRenderer.networkWidth)
        for image in images {
            XCTAssertEqual(image.size, images[0].size)
            XCTAssertEqual(image.size.height, 22)
        }
    }

}
