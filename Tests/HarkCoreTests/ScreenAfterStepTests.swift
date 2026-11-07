import XCTest
@testable import HarkCore

final class ScreenSettleTests: XCTestCase {
    private let still = [UInt8](repeating: 0, count: 32 * 32)
    private let changed = [UInt8](repeating: 200, count: 32 * 32)
    private let changedAgain = [UInt8](repeating: 90, count: 32 * 32)

    func testNothingMovingEndsAtTheReactionTime() {
        var settle = ScreenSettle(before: still, times: (0.7, 0.25, 2.5))
        XCTAssertFalse(settle.isDone(still, at: 0.2))
        XCTAssertFalse(settle.isDone(still, at: 0.6))
        XCTAssertTrue(settle.isDone(still, at: 0.7))
    }

    func testOldPageStayingUpIsNotSettled() {
        // Still frames at first, then the new page arrives: the first quiet moment isn't the end.
        var settle = ScreenSettle(before: still, times: (1.5, 0.25, 4))
        XCTAssertFalse(settle.isDone(still, at: 0.2))
        XCTAssertFalse(settle.isDone(still, at: 0.4))
        XCTAssertFalse(settle.isDone(changed, at: 0.9))
        XCTAssertFalse(settle.isDone(changed, at: 1.0))
        XCTAssertTrue(settle.isDone(changed, at: 1.2))
    }

    func testMovementRestartsTheQuietTime() {
        var settle = ScreenSettle(before: still, times: (0.7, 0.25, 2.5))
        XCTAssertFalse(settle.isDone(changed, at: 0.2))
        XCTAssertFalse(settle.isDone(changedAgain, at: 0.4))
        XCTAssertFalse(settle.isDone(changedAgain, at: 0.6))
        XCTAssertTrue(settle.isDone(changedAgain, at: 0.7))
    }

    func testAScreenThatNeverStopsEndsAtTheLimit() {
        var settle = ScreenSettle(before: still, times: (0.3, 0.25, 1.5))
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
    private func call(_ id: String, _ name: String = "mcp__hark__click", message: String = "m1") -> [String: Any] {
        ["type": "assistant", "message": ["id": message, "content": [["type": "tool_use", "id": id, "name": name, "input": [:]]]]]
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

    func testALostResultCanNeverStickAcrossMessages() {
        // The real failure: one result never arrived, and every later step thought another was queued.
        let queue = ToolQueue()
        queue.note(call("a", message: "m1"))
        queue.note(call("b", message: "m2"))
        XCTAssertFalse(queue.moreQueued)
        queue.note(answer("b"))
        queue.note(call("c", message: "m3"))
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

final class ReadInOrderTests: XCTestCase {
    private actor Lines {
        private var buffer = Data()
        private(set) var numbers: [Int] = []
        private(set) var garbled = 0

        func receive(_ chunk: Data) {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let number = json["n"] as? Int {
                    numbers.append(number)
                } else {
                    garbled += 1
                }
            }
        }
    }

    /// Lines bigger than a pipe's chunk, like every screenshot from Claude Code: none may be lost or scrambled.
    func testBigLinesArriveWhole() async throws {
        let total = 300
        let pipe = Pipe()
        let lines = Lines()
        pipe.fileHandleForReading.readInOrder { await lines.receive($0) }
        let writer = pipe.fileHandleForWriting
        DispatchQueue.global().async {
            for number in 0..<total {
                let padding = String(repeating: "x", count: number.isMultiple(of: 3) ? 170_000 : 300)
                writer.write(Data("{\"n\":\(number),\"pad\":\"\(padding)\"}\n".utf8))
            }
            try? writer.close()
        }
        for _ in 0..<200 {
            let done = await lines.numbers.count + lines.garbled
            if done == total { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let garbled = await lines.garbled
        let numbers = await lines.numbers
        XCTAssertEqual(garbled, 0)
        XCTAssertEqual(numbers, Array(0..<total))
    }
}

final class ConversationMemoryTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: "ConversationMemoryTests")!
    private let now = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() { defaults.removePersistentDomain(forName: "ConversationMemoryTests") }

    private var memory: ConversationMemory { ConversationMemory(key: "Test", idle: 1800, defaults: defaults) }

    func testNothingSavedStartsNew() {
        XCTAssertNil(memory.current(at: now))
    }

    func testCarriesOnWhileRecent() {
        memory.save("a", at: now)
        XCTAssertEqual(memory.current(at: now.addingTimeInterval(1799)), "a")
    }

    func testStartsNewAfterTheIdleTime() {
        memory.save("a", at: now)
        XCTAssertNil(memory.current(at: now.addingTimeInterval(1800)))
    }

    func testActivityKeepsItGoing() {
        memory.save("a", at: now)
        memory.save("a", at: now.addingTimeInterval(1700))
        XCTAssertEqual(memory.current(at: now.addingTimeInterval(3000)), "a")
    }

    func testForgetting() {
        memory.save("a", at: now)
        memory.forget()
        XCTAssertNil(memory.current(at: now))
    }
}

/// The real Claude Code CLI: run with HARK_LIVE_CLAUDE=1. It costs a few tiny requests.
final class LiveConversationTests: XCTestCase {
    private let key = "LiveConversationTest-\(UUID().uuidString)"

    private func session() -> LiveClaude {
        LiveClaude(label: "Test", systemPrompt: "Be brief. Follow instructions exactly.", model: "haiku", timeout: 90,
                   arguments: ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--tools", ""],
                   turnLimit: .max, idleMinutes: 30, conversationKey: key)
    }

    func testAConversationSurvivesEverythingButIdleTime() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HARK_LIVE_CLAUDE"] == "1", "needs the real CLI")
        let question = "What was the codeword? Reply with just the word, or NONE if you were never given one."
        let first = session()
        _ = try await first.ask("Remember the codeword TEALOTTER. Reply: ok")

        // The process stops, as it does on Stop or after an error: the next request carries on.
        await first.stop()
        let afterStop = try await first.ask(question)
        XCTAssertTrue(afterStop.contains("TEALOTTER"), afterStop)

        // A new session object with the same key: a relaunched Hark.
        await first.stop()
        let relaunched = session()
        let afterRelaunch = try await relaunched.ask(question)
        XCTAssertTrue(afterRelaunch.contains("TEALOTTER"), afterRelaunch)

        // Summarizing keeps it.
        await relaunched.compact(above: 0)
        let afterCompact = try await relaunched.ask(question)
        XCTAssertTrue(afterCompact.contains("TEALOTTER"), afterCompact)

        // A conversation that's gone doesn't lose the request: it starts over and still answers.
        await relaunched.stop()
        UserDefaults.standard.set("11111111-2222-4333-8444-555555555555", forKey: key)
        let gone = session()
        let afterGone = try await gone.ask("Reply with just the word pong.")
        XCTAssertTrue(afterGone.lowercased().contains("pong"), afterGone)
        XCTAssertFalse(afterGone.contains("TEALOTTER"), afterGone)

        // Idle too long: a new conversation.
        await gone.stop()
        _ = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(Date(timeIntervalSinceNow: -3600), forKey: key + "Used")
        let afterIdle = try await session().ask("Reply with just the word NEW if this is the first message of our chat, otherwise OLD.")
        XCTAssertTrue(afterIdle.contains("NEW"), afterIdle)
    }
}
