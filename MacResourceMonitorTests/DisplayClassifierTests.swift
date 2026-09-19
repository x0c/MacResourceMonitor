import MacKitCore
import XCTest
@testable import MacResourceMonitor

final class DisplayClassifierTests: XCTestCase {
    func testChatGPTFamilyFoldsHelpersAndMemory() {
        let chatgpt = makeProcess(
            pid: 10,
            path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
            arguments: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"]
        )
        let cua = makeProcess(
            pid: 11,
            ppid: 10,
            path: "/opt/homebrew/bin/node",
            arguments: ["node", "/tmp/cua_node/index.js"],
            responsible: 10
        )
        let memory = makeProcess(
            pid: 12,
            ppid: 11,
            path: "/opt/homebrew/bin/node",
            arguments: ["node", "/tmp/mcp-server-memory/index.js"],
            responsible: 10
        )
        let rows = DisplayClassifier.rows(from: [chatgpt, cua, memory], currentUID: 501, physicalMemory: 16 << 30)
        XCTAssertEqual(rows.filter { $0.displayName == "ChatGPT" }.count, 1)
        XCTAssertFalse(rows.contains { $0.displayName.localizedCaseInsensitiveContains("node") })
        XCTAssertFalse(rows.contains { $0.displayName.contains("mcp-server-memory") })
        XCTAssertEqual(rows.first { $0.displayName == "ChatGPT" }?.memberPIDs.sorted(), [10, 11, 12])
    }

    func testEachCursorAgentIsItsOwnRow() {
        let tmux = makeProcess(pid: 20, path: "/opt/homebrew/bin/tmux", arguments: ["tmux"])
        let agent1 = makeProcess(
            pid: 21,
            ppid: 20,
            path: "/Users/me/.local/share/cursor-agent/agent",
            arguments: ["agent", "--workspace", "a"]
        )
        let agent2 = makeProcess(
            pid: 22,
            ppid: 20,
            path: "/Users/me/.local/share/cursor-agent/agent",
            arguments: ["agent", "--workspace", "b"]
        )
        let cursorApp = makeProcess(
            pid: 23,
            path: "/Applications/Cursor.app/Contents/MacOS/Cursor",
            arguments: ["Cursor"]
        )
        let rows = DisplayClassifier.rows(
            from: [tmux, agent1, agent2, cursorApp],
            currentUID: 501,
            physicalMemory: 16 << 30
        )
        let agents = rows.filter { $0.displayName == "Cursor Agent" }
        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(Set(agents.flatMap(\.memberPIDs)), Set([21, 22]))
        XCTAssertEqual(rows.filter { $0.displayName == "Cursor" }.count, 1)
    }

    func testStandaloneToolLaunchedFromCursorIsNotFolded() {
        let cursor = makeProcess(
            pid: 80,
            path: "/Applications/Cursor.app/Contents/MacOS/Cursor",
            arguments: ["Cursor"]
        )
        let tool = makeProcess(
            pid: 81,
            ppid: 80,
            path: "/usr/bin/yes",
            arguments: ["mac-resource-monitor-end-test"],
            responsible: 80
        )
        let rows = DisplayClassifier.rows(from: [cursor, tool], currentUID: 501, physicalMemory: 16 << 30)
        XCTAssertEqual(rows.first { $0.displayName == "mac-resource-monitor-end-test" }?.memberPIDs, [81])
        XCTAssertEqual(rows.first { $0.displayName == "Cursor" }?.memberPIDs, [80])
    }

    func testPiAndCorralAreHumanNamedAndNotPython() {
        let python = makeProcess(
            pid: 30,
            path: "/opt/homebrew/Cellar/python@3.13/3.13.5/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python",
            arguments: ["Python", "/Users/me/.local/bin/corral", "serve"]
        )
        let pi = makeProcess(
            pid: 31,
            ppid: 40,
            path: "/opt/homebrew/bin/node",
            arguments: ["node", "/opt/homebrew/bin/pi"]
        )
        let tmux = makeProcess(pid: 40, path: "/opt/homebrew/bin/tmux", arguments: ["tmux"])
        let rows = DisplayClassifier.rows(from: [python, pi, tmux], currentUID: 501, physicalMemory: 16 << 30)
        XCTAssertTrue(rows.contains { $0.displayName == "Corral" })
        XCTAssertTrue(rows.contains { $0.displayName == "pi" })
        XCTAssertFalse(rows.contains { $0.displayName.lowercased() == "python3" })
        XCTAssertFalse(rows.contains { $0.displayName == "Python" })
        XCTAssertEqual(rows.first { $0.displayName == "pi" }?.memberPIDs, [31])
    }

    func testMCPMemoryDoesNotOccupyARow() {
        let terminal = makeProcess(
            pid: 50,
            path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            arguments: ["Terminal"]
        )
        let memory = makeProcess(
            pid: 51,
            ppid: 50,
            path: "/opt/homebrew/bin/node",
            arguments: ["node", "mcp-server-memory"],
            responsible: 50
        )
        let rows = DisplayClassifier.rows(from: [terminal, memory], currentUID: 501, physicalMemory: 16 << 30)
        XCTAssertFalse(rows.contains { $0.displayName.contains("mcp-server-memory") })
        XCTAssertFalse(rows.contains { $0.displayName == "node" })
    }

    func testWindowServerCannotBeEnded() {
        let windowServer = makeProcess(
            pid: 88,
            uid: 88,
            path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            arguments: ["WindowServer"]
        )
        let rows = DisplayClassifier.rows(from: [windowServer], currentUID: 501, physicalMemory: 16 << 30)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(
            DisplayClassifier.isProtected(name: "WindowServer", path: windowServer.path, pid: 88)
        )
        XCTAssertEqual(rows[0].kind, .other)
        XCTAssertTrue(rows[0].isSystemProtected, "kind=\(rows[0].kind) name=\(rows[0].displayName)")
        XCTAssertFalse(rows[0].isCurrentUser)
        XCTAssertNil(
            DisplayClassifier.toolHint(
                path: windowServer.path,
                arguments: windowServer.arguments,
                executableName: "WindowServer"
            )
        )
    }

    func testProtectedSystemHelperIsNotFoldedIntoDesktopApp() {
        let safari = makeProcess(
            pid: 200,
            path: "/Applications/Safari.app/Contents/MacOS/Safari",
            arguments: ["Safari"]
        )
        let helper = makeProcess(
            pid: 201,
            ppid: 200,
            uid: 0,
            path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            arguments: ["WindowServer"],
            responsible: 200
        )
        let rows = DisplayClassifier.rows(from: [safari, helper], currentUID: 501, physicalMemory: 16 << 30)
        let appRow = rows.first { $0.id.hasPrefix("app:") }
        let protectedRow = rows.first { $0.memberPIDs == [201] }
        XCTAssertEqual(appRow?.memberPIDs, [200])
        XCTAssertNotNil(protectedRow)
        XCTAssertTrue(protectedRow?.isSystemProtected == true)
        XCTAssertFalse(appRow?.memberPIDs.contains(201) == true)
    }

    func testUsrSbinIsProtected() {
        XCTAssertTrue(
            DisplayClassifier.isProtected(
                name: "blued",
                path: "/usr/sbin/blued",
                pid: 99
            )
        )
    }

    func testNetworkSamplerIsNotNamedZeroAndFoldsIntoMonitor() {
        let arguments = [
            "/usr/bin/nettop", "-d", "-P", "-L", "0", "-s", "1", "-x", "-n",
            "-J", "bytes_in,bytes_out"
        ]
        XCTAssertNil(
            DisplayClassifier.toolHint(
                path: "/usr/bin/nettop",
                arguments: arguments,
                executableName: "nettop"
            )
        )
        let app = makeProcess(
            pid: 90,
            path: "/Applications/Mac Resource Monitor.app/Contents/MacOS/Mac Resource Monitor",
            arguments: ["Mac Resource Monitor"]
        )
        let sampler = makeProcess(
            pid: 91,
            ppid: 1,
            path: "/usr/bin/nettop",
            arguments: arguments
        )
        let rows = DisplayClassifier.rows(from: [app, sampler], currentUID: 501, physicalMemory: 16 << 30)
        XCTAssertFalse(rows.contains { $0.displayName == "0" })
        XCTAssertEqual(rows.filter { $0.displayName == "Mac Resource Monitor" }.count, 1)
        XCTAssertEqual(
            rows.first { $0.displayName == "Mac Resource Monitor" }?.memberPIDs.sorted(),
            [90, 91]
        )
    }

    func testCPUPercentIsCappedAtOneHundred() {
        let value = CPUTime.percent(tickDelta: 1_000_000_000_000, wallSeconds: 1, logicalCores: 8)
        XCTAssertLessThanOrEqual(value, 100)
    }

    func testPanelDismissKeepsStatusItem() {
        let panel = KitRect(x: 100, y: 100, width: 400, height: 400)
        let item = KitRect(x: 900, y: 880, width: 24, height: 22)
        XCTAssertFalse(PanelDismissPolicy.shouldHide(click: KitPoint(x: 200, y: 200), keptFrames: [panel, item]))
        XCTAssertFalse(PanelDismissPolicy.shouldHide(click: KitPoint(x: 910, y: 890), keptFrames: [panel, item]))
        XCTAssertTrue(PanelDismissPolicy.shouldHide(click: KitPoint(x: 10, y: 10), keptFrames: [panel, item]))
    }

    private func makeProcess(
        pid: pid_t,
        ppid: pid_t = 1,
        uid: uid_t = 501,
        path: String,
        arguments: [String],
        responsible: pid_t? = nil
    ) -> RawProcess {
        RawProcess(
            identity: ProcessIdentity(pid: pid, startTime: 1),
            ppid: ppid,
            uid: uid,
            path: path,
            arguments: arguments,
            responsiblePID: responsible ?? pid,
            cpuPercent: 1,
            memoryBytes: 10_000_000
        )
    }
}
