import XCTest
@testable import MacResourceMonitor

@MainActor
final class TransientStatusMessageTests: XCTestCase {
    func testPresentClearsAfterDuration() async throws {
        XCTAssertEqual(TransientStatusMessage.displayDuration, .seconds(3))
        let banner = TransientStatusMessage()
        var text: String?
        banner.present("Some processes could not be ended.", duration: .milliseconds(40)) {
            text = $0
        }
        XCTAssertEqual(text, "Some processes could not be ended.")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(text)
    }

    func testLaterPresentInvalidatesEarlierClear() async throws {
        let banner = TransientStatusMessage()
        var text: String?
        banner.present("first", duration: .milliseconds(40)) { text = $0 }
        try await Task.sleep(for: .milliseconds(20))
        banner.present("second", duration: .milliseconds(80)) { text = $0 }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(text, "second")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(text)
    }

    func testCancelInvalidatesPendingTimer() async throws {
        let banner = TransientStatusMessage()
        var text: String?
        banner.present("first", duration: .milliseconds(40)) { text = $0 }
        banner.cancel()
        XCTAssertNil(text)
        banner.present("second", duration: .milliseconds(80)) { text = $0 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(text, "second")
    }
}
