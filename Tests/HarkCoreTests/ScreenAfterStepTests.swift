import XCTest
@testable import HarkCore

final class ScreenSettleTests: XCTestCase {
    private let still = [UInt8](repeating: 0, count: 32 * 32)
    private let changed = [UInt8](repeating: 200, count: 32 * 32)
    private let changedAgain = [UInt8](repeating: 90, count: 32 * 32)

    func testNothingMovingEndsAtTheReactionTime() {
        var settle = ScreenSettle(before: still, reaction: 0.7, limit: 2.5)
        XCTAssertFalse(settle.isDone(still, at: 0.2))
        XCTAssertFalse(settle.isDone(still, at: 0.6))
        XCTAssertTrue(settle.isDone(still, at: 0.7))
    }

    func testOldPageStayingUpIsNotSettled() {
        // Still frames at first, then the new page arrives: the first quiet moment isn't the end.
        var settle = ScreenSettle(before: still, reaction: 1.5, limit: 4)
        XCTAssertFalse(settle.isDone(still, at: 0.2))
        XCTAssertFalse(settle.isDone(still, at: 0.4))
        XCTAssertFalse(settle.isDone(changed, at: 0.9))
        XCTAssertFalse(settle.isDone(changed, at: 1.0))
        XCTAssertTrue(settle.isDone(changed, at: 1.2))
    }

    func testMovementRestartsTheQuietTime() {
        var settle = ScreenSettle(before: still, reaction: 0.7, limit: 2.5)
        XCTAssertFalse(settle.isDone(changed, at: 0.2))
        XCTAssertFalse(settle.isDone(changedAgain, at: 0.4))
        XCTAssertFalse(settle.isDone(changedAgain, at: 0.6))
        XCTAssertTrue(settle.isDone(changedAgain, at: 0.7))
    }

    func testAScreenThatNeverStopsEndsAtTheLimit() {
        var settle = ScreenSettle(before: still, reaction: 0.3, limit: 1.5)
        for (step, elapsed) in stride(from: 0.2, to: 1.5, by: 0.2).enumerated() {
            XCTAssertFalse(settle.isDone(step.isMultiple(of: 2) ? changed : changedAgain, at: elapsed))
        }
        XCTAssertTrue(settle.isDone(changed, at: 1.5))
    }

    @MainActor
    func testEveryStepThatBringsTheScreenIsARealTool() {
        let names = Set(HarkEngine.mcpTools().compactMap { $0["name"] as? String })
        XCTAssertEqual(Set(Tools.settling.keys).subtracting(names), [])
    }
}

/// Event shapes are the ones Claude Code's stream-json prints.
final class ToolQueueTests: XCTestCase {
    private func call(_ id: String, _ name: String = "mcp__hark__click") -> [String: Any] {
        ["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": [:]]]]]
    }
    private func answer(_ id: String) -> [String: Any] {
        ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": []]]]]
    }

    func testASingleStepHasNothingQueued() {
        let queue = ToolQueue()
        queue.note(call("a"))
        XCTAssertFalse(queue.moreQueued)
    }

    func testOnlyTheLastStepOfAMessageIsLast() {
        let queue = ToolQueue()
        queue.note(call("a"))
        queue.note(call("b"))
        queue.note(call("c"))
        XCTAssertTrue(queue.moreQueued)   // a running
        queue.note(answer("a"))
        XCTAssertTrue(queue.moreQueued)   // b running
        queue.note(answer("b"))
        XCTAssertFalse(queue.moreQueued)  // c running: it brings the screen
    }

    func testOtherServersToolsDontCount() {
        let queue = ToolQueue()
        queue.note(call("a"))
        queue.note(call("b", "ToolSearch"))
        queue.note(call("c", "mcp__claude_ai_Google_Drive__search"))
        XCTAssertFalse(queue.moreQueued)
    }

    func testAStoppedRunLeavesNothingBehind() {
        let queue = ToolQueue()
        queue.note(call("a"))
        queue.note(call("b"))
        queue.clear()
        queue.note(call("c"))
        XCTAssertFalse(queue.moreQueued)
    }

    func testTheEndOfARequestClearsTheQueue() {
        let queue = ToolQueue()
        queue.note(call("a"))
        queue.note(call("b"))
        queue.note(["type": "result", "subtype": "success"])
        queue.note(call("c"))
        XCTAssertFalse(queue.moreQueued)
    }
}
