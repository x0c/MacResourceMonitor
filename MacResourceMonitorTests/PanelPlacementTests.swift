import XCTest
@testable import MacResourceMonitor

final class PanelPlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let visible = NSRect(x: 0, y: 80, width: 1440, height: 796)
    private let size = AppPreferences.compactSize

    func testZeroAnchorDoesNotFallToBottomLeft() {
        let origin = PanelPlacement.origin(
            anchor: .zero,
            size: size,
            screens: [screen],
            visibleScreens: [visible],
            fallbackVisible: visible
        )
        XCTAssertGreaterThan(origin.x, 100)
        XCTAssertGreaterThan(origin.y, 400)
        XCTAssertEqual(origin.y, visible.maxY - size.height - 6, accuracy: 0.5)
    }

    func testMenuBarIconPlacesPanelJustBelow() {
        let icon = NSRect(x: 1200, y: 876, width: 22, height: 22)
        XCTAssertTrue(PanelPlacement.isMenuBarAnchor(icon, screens: [screen]))
        let origin = PanelPlacement.origin(
            anchor: icon,
            size: size,
            screens: [screen],
            visibleScreens: [visible],
            fallbackVisible: visible
        )
        XCTAssertEqual(origin.x, icon.midX - size.width / 2, accuracy: 0.5)
        XCTAssertEqual(origin.y, icon.minY - size.height - 6, accuracy: 0.5)
    }

    func testBottomMenuBarIconPlacesPanelTowardTheVisibleScreen() {
        let icon = NSRect(x: 1200, y: 2, width: 22, height: 22)
        XCTAssertTrue(PanelPlacement.isMenuBarAnchor(icon, screens: [screen]))
        let origin = PanelPlacement.origin(
            anchor: icon,
            size: size,
            screens: [screen],
            visibleScreens: [screen],
            fallbackVisible: visible
        )
        XCTAssertEqual(origin.x, icon.midX - size.width / 2, accuracy: 0.5)
        XCTAssertEqual(origin.y, icon.maxY + 6, accuracy: 0.5)
    }

    func testMissingAnchorUsesTopOfVisibleArea() {
        let origin = PanelPlacement.origin(
            anchor: nil,
            size: size,
            screens: [screen],
            visibleScreens: [visible],
            fallbackVisible: visible
        )
        XCTAssertEqual(origin.x, visible.midX - size.width / 2, accuracy: 0.5)
        XCTAssertEqual(origin.y, visible.maxY - size.height - 6, accuracy: 0.5)
    }
}
