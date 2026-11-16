import XCTest
@testable import MacResourceMonitor

final class EndWhitelistTests: XCTestCase {
    func testBundlePathMatchProtectsApp() {
        let row = makeRow(name: "Google Chrome", bundle: "/Applications/Google Chrome.app")
        let entry = WhitelistedApp(displayName: "Google Chrome", bundlePath: "/Applications/Google Chrome.app")
        XCTAssertTrue(entry.matches(row: row))
    }

    func testDisplayNameFallbackSurvivesMove() {
        var row = makeRow(name: "Google Chrome", bundle: "/Applications/Google Chrome.app")
        row.bundlePath = "/Users/me/Apps/Google Chrome.app"
        let entry = WhitelistedApp(displayName: "google chrome", bundlePath: "/Applications/Google Chrome.app")
        XCTAssertTrue(entry.matches(row: row))
    }

    func testToolNameMatchIsCaseInsensitive() {
        let row = makeRow(name: "pi", bundle: nil)
        let entry = WhitelistedApp(displayName: "PI")
        XCTAssertTrue(entry.matches(row: row))
    }

    func testDifferentNameDoesNotMatch() {
        let row = makeRow(name: "Safari", bundle: "/Applications/Safari.app")
        let entry = WhitelistedApp(displayName: "Google Chrome", bundlePath: "/Applications/Google Chrome.app")
        XCTAssertFalse(entry.matches(row: row))
    }

    func testBulkCandidatesSkipWhitelisted() {
        let keep = makeRow(name: "KeepMe", bundle: nil, pid: 101)
        let other = makeRow(name: "Other", bundle: nil, pid: 102)
        let whitelist = [WhitelistedApp(displayName: "KeepMe")]
        let candidates = ProcessTerminationSelection.bulkCandidates(from: [keep, other], excludingPID: 999, whitelist: whitelist)
        XCTAssertEqual(candidates.map(\.displayName), ["Other"])
    }

    func testSaveLoadRoundTrip() {
        let defaults = UserDefaults(suiteName: "whitelist-test-\(UUID().uuidString)")!
        let entries = [
            WhitelistedApp(displayName: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", kindRaw: "desktopApp"),
            WhitelistedApp(displayName: "pi", kindRaw: "pi"),
        ]
        EndWhitelist.save(entries, to: defaults)
        let loaded = EndWhitelist.load(from: defaults)
        XCTAssertEqual(loaded, entries.sorted { $0.displayName < $1.displayName })
    }

    func testEntryFromRowCarriesIconPaths() {
        var row = makeRow(name: "Example", bundle: "/Applications/Example.app")
        row.iconPath = "/Applications/Example.app"
        row.executablePath = "/Applications/Example.app/Contents/MacOS/Example"
        let entry = WhitelistedApp(row: row)
        XCTAssertEqual(entry.iconPath, "/Applications/Example.app")
        XCTAssertEqual(entry.executablePath, "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertEqual(entry.displayIconPath, "/Applications/Example.app")
    }

    func testMatchingIgnoresIconFields() {
        let row = makeRow(name: "pi", bundle: nil)
        let withoutIcon = WhitelistedApp(displayName: "pi", kindRaw: "pi")
        var withIcon = withoutIcon
        withIcon.iconPath = "/opt/homebrew/bin/pi"
        withIcon.executablePath = "/opt/homebrew/bin/node"
        XCTAssertTrue(withoutIcon.matches(row: row))
        XCTAssertTrue(withIcon.matches(row: row))
    }

    func testLegacyEntriesWithoutIconKeysStillDecode() {
        let legacy = #"[{"displayName":"Old App","bundlePath":"/Applications/Old.app","kindRaw":"desktopApp"}]"#
        let entries = try! JSONDecoder().decode([WhitelistedApp].self, from: Data(legacy.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].iconPath)
        XCTAssertEqual(entries[0].displayIconPath, "/Applications/Old.app")
    }

    private func makeRow(name: String, bundle: String?, pid: pid_t = 1) -> ProcessRow {
        ProcessRow(
            id: name,
            displayName: name,
            bundlePath: bundle,
            iconPath: nil,
            executablePath: "/tmp/\(name)",
            memberIdentities: [ProcessIdentity(pid: pid, startTime: 1)],
            cpuPercent: 1,
            memoryPercent: 1,
            kind: bundle == nil ? .other : .desktopApp,
            isCurrentUser: true,
            isSystemProtected: false
        )
    }
}
