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

    func testFittedHeightDoesNotCrossVisibleBottom() {
        let icon = NSRect(x: 1200, y: 876, width: 22, height: 22)
        let size = PanelPlacement.fittedSize(
            preferredHeight: 5000,
            minHeight: AppPreferences.compactHeightMin,
            width: AppPreferences.compactWidth,
            anchor: icon,
            screens: [screen],
            visibleScreens: [visible],
            fallbackVisible: visible
        )
        let origin = PanelPlacement.origin(
            anchor: icon,
            size: size,
            screens: [screen],
            visibleScreens: [visible],
            fallbackVisible: visible
        )
        XCTAssertGreaterThanOrEqual(origin.y, visible.minY + 8 - 0.5)
        XCTAssertEqual(origin.y + size.height, icon.minY - 6, accuracy: 0.5)
        XCTAssertEqual(size.height, icon.minY - 6 - (visible.minY + 8), accuracy: 0.5)
        XCTAssertTrue(PanelPlacement.growsDownward(anchor: icon, screens: [screen]))
    }

    func testFittedHeightKeepsPreferredWhenItFits() {
        let icon = NSRect(x: 1200, y: 876, width: 22, height: 22)
        let size = PanelPlacement.fittedSize(
            preferredHeight: 360,
            minHeight: AppPreferences.compactHeightMin,
            width: AppPreferences.compactWidth,
            anchor: icon,
            screens: [screen],
            visibleScreens: [visible],
            fallbackVisible: visible
        )
        XCTAssertEqual(size.height, 360, accuracy: 0.5)
        XCTAssertEqual(size.width, AppPreferences.compactWidth, accuracy: 0.5)
    }

    func testBottomMenuBarFittedHeightDoesNotCrossVisibleTop() {
        let icon = NSRect(x: 1200, y: 2, width: 22, height: 22)
        let size = PanelPlacement.fittedSize(
            preferredHeight: 5000,
            minHeight: AppPreferences.compactHeightMin,
            width: AppPreferences.compactWidth,
            anchor: icon,
            screens: [screen],
            visibleScreens: [screen],
            fallbackVisible: visible
        )
        let origin = PanelPlacement.origin(
            anchor: icon,
            size: size,
            screens: [screen],
            visibleScreens: [screen],
            fallbackVisible: visible
        )
        XCTAssertEqual(origin.y, icon.maxY + 6, accuracy: 0.5)
        XCTAssertLessThanOrEqual(origin.y + size.height, screen.maxY + 0.5)
        XCTAssertFalse(PanelPlacement.growsDownward(anchor: icon, screens: [screen]))
    }

    func testMissingHeightKeyUsesDefaultNotZero() {
        let defaults = UserDefaults(suiteName: "test.panel.height.missing")!
        defaults.removePersistentDomain(forName: "test.panel.height.missing")
        XCTAssertEqual(AppPreferences.readCompactHeight(defaults: defaults), AppPreferences.compactHeightDefault)
        AppPreferences.writeCompactHeight(480, defaults: defaults)
        XCTAssertEqual(AppPreferences.readCompactHeight(defaults: defaults), 480, accuracy: 0.5)
        defaults.set(0, forKey: AppPreferences.compactHeightKey)
        XCTAssertEqual(AppPreferences.readCompactHeight(defaults: defaults), AppPreferences.compactHeightDefault)
        defaults.removePersistentDomain(forName: "test.panel.height.missing")
    }
}
