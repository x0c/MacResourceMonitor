import XCTest
@testable import MacResourceMonitor

final class TableMetricPresentationTests: XCTestCase {
    func testNetworkRateUsesTheTableHeatLadder() {
        XCTAssertEqual(TableMetricPresentation.level(for: 0, metric: .network), .quiet)
        XCTAssertEqual(TableMetricPresentation.level(for: 1_023, metric: .network), .quiet)
        XCTAssertEqual(TableMetricPresentation.level(for: 1_024, metric: .network), .normal)
        XCTAssertEqual(TableMetricPresentation.level(for: 1_024 * 1_024, metric: .network), .elevated)
        XCTAssertEqual(TableMetricPresentation.level(for: 10 * 1_024 * 1_024, metric: .network), .critical)
    }

    func testCPUAndMemoryKeepTheirExistingLevels() {
        XCTAssertEqual(TableMetricPresentation.level(for: 0.5, metric: .cpu), .quiet)
        XCTAssertEqual(TableMetricPresentation.level(for: 5, metric: .cpu), .elevated)
        XCTAssertEqual(TableMetricPresentation.level(for: 15, metric: .cpu), .critical)
        XCTAssertEqual(TableMetricPresentation.level(for: 7.9, metric: .memory), .quiet)
        XCTAssertEqual(TableMetricPresentation.level(for: 8, metric: .memory), .normal)
    }
}
