import XCTest
@testable import HarkCore

final class AppleScriptTests: XCTestCase {
    func testReturnsTheResult() async throws {
        let value = try await AppleScript.run("return 6 * 7")
        XCTAssertEqual(value, "42")
    }

    func testGivesUpAtTheDeadlineAndRecovers() async throws {
        let start = Date()
        do {
            _ = try await AppleScript.run("delay 2", deadline: 0.3)
            XCTFail("a stuck script should fail at the deadline")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
        // Queued behind the stuck script: it waits for it, then runs.
        let value = try await AppleScript.run("return \"next\"", deadline: 5)
        XCTAssertEqual(value, "next")
    }

    func testAScriptGivenUpOnNeverRunsLate() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("hark-late-\(UUID().uuidString)")
        async let stuck = try? AppleScript.run("delay 1", deadline: 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try? await AppleScript.run("do shell script \"touch \(marker.path)\"", deadline: 0.2)
        _ = await stuck
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
