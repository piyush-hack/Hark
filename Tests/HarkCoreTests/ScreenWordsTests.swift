import XCTest
@testable import HarkCore

final class ScreenWordsTests: XCTestCase {
    let dictionary: Set<String> = ["templates", "template", "send", "ask", "about", "the", "build", "save", "built", "in", "tools",
                                   "workflow", "node", "add", "mapping", "variable", "map", "table", "real", "time"]
    func isWord(_ word: String) -> Bool { dictionary.contains(word.lowercased()) }

    func testTermsAreTheWordsSpeechRecognitionDoesntKnow() {
        let terms = ScreenWords.terms(in: ["WABA Templates", "Send template · WABA", "FluidAudio 0.8.2", "Ask Piyush about the build",
                                           "SAVE", "built-in tools", "real-time", "key sk-abc123def456ghi789", "html_to_pdf", "devs@example.com"],
                                      isWord: isWord)
        XCTAssertEqual(terms.first, "WABA", "seen most often")
        for term in ["FluidAudio", "Piyush", "html_to_pdf"] { XCTAssertTrue(terms.contains(term), term) }
        for word in ["SAVE", "built-in", "real-time", "Templates", "sk-abc123def456ghi789", "devs@example.com"] {
            XCTAssertFalse(terms.contains(word), word)
        }
    }

    func testSecretsAndAddressesNeverLeave() {
        XCTAssertTrue(ScreenWords.looksSecret("ghp_abcdef1234567890abcd"))
        XCTAssertTrue(ScreenWords.looksSecret("3f9a0c4e8b7d6a5f"))
        XCTAssertTrue(ScreenWords.looksSecret("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(ScreenWords.looksSecret("FluidAudio"))
        XCTAssertEqual(ScreenWords.scrub("token ghp_abcdef1234567890abcd, mail devs@example.com now"), "token … mail … now")
    }

    func testSoundAlikesPairWhatWasHeardWithTheScreen() {
        let node = ScreenWords.soundAlikes(in: "Through contact details, page or through workflow mode", terms: ["WABA"],
                                           labels: ["Workflow node", "Add node"])
        XCTAssertTrue(node.contains { $0.heard == "workflow mode" && $0.screen == "Workflow node" }, "\(node)")
        let fluid = ScreenWords.soundAlikes(in: "fluid audio for speech", terms: ["FluidAudio"], labels: [])
        XCTAssertTrue(fluid.contains { $0.heard == "fluid audio" && $0.screen == "FluidAudio" }, "\(fluid)")
    }

    func testSoundAlikesLeaveOrdinarySpeechAlone() {
        XCTAssertTrue(ScreenWords.soundAlikes(in: "Switch to dark mode first", terms: [], labels: ["Workflow node"]).isEmpty)
        XCTAssertTrue(ScreenWords.soundAlikes(in: "I will make the node bigger", terms: ["Node"], labels: ["Add node"]).isEmpty,
                      "the same word in another case isn't a mishearing")
        XCTAssertTrue(ScreenWords.soundAlikes(in: "go to the map", terms: [], labels: ["to the"]).isEmpty, "small words don't pair")
    }

    func testLinesShowingWhatHarkTypedAreLeftOut() {
        let typed = ScreenWords.words("If some variables are filled out. And do the same in Waka template mapping also")
        let grams = ScreenWords.trigrams(typed)
        XCTAssertTrue(ScreenWords.shows(typed, grams: grams, in: "And do the same in Waka template"), "the field, read back")
        XCTAssertTrue(ScreenWords.shows(typed, grams: grams, in: "Waka"), "a wrapped piece of it")
        XCTAssertFalse(ScreenWords.shows(typed, grams: grams, in: "WABA Templates"))
        XCTAssertFalse(ScreenWords.shows([], grams: [], in: "WABA Templates"))
    }

    func testNearestLinesAreAroundTheFieldNotInIt() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let field = CGRect(x: 100, y: 700, width: 800, height: 60)
        func line(_ text: String, y: CGFloat) -> OCRLine { OCRLine(text: text, frame: CGRect(x: 120, y: y, width: 300, height: 18)) }
        let lines = [line("Far away header", y: 10), line("Message from Piyush about WABA", y: 640), line("Earlier message", y: 600),
                     line("What I'm typing", y: 720)]
        XCTAssertEqual(ScreenWords.nearest(lines, to: field, in: window, budget: 60), ["Earlier message", "Message from Piyush about WABA"])
        XCTAssertEqual(ScreenWords.nearest(lines, to: window.insetBy(dx: 10, dy: 10), in: window), [], "a document fills the window")
        XCTAssertEqual(ScreenWords.nearest(lines, to: nil, in: window), [])
    }
}
