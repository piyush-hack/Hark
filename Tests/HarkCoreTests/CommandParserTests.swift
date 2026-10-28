import XCTest
@testable import HarkCore

final class CommandParserTests: XCTestCase {
    let parser = CommandParser(apps: ["Google Chrome", "Safari", "Visual Studio Code", "System Settings", "Terminal",
                                      "Finder", "Spotify", "Notes", "Slack", "WhatsApp", "Brave Browser", "Calculator"])

    func plan(_ text: String) -> [Command] { parser.plan(text) }

    func testChainedBrowserCommands() {
        XCTAssertEqual(plan("Open Chrome, open a new tab and search for the best ramen in Tokyo."), [
            .openApp("Google Chrome"), .browser(.newTab), .searchHere("the best ramen in Tokyo"),
        ])
        XCTAssertEqual(plan("open chrome then new tab then go to github.com"), [
            .openApp("Google Chrome"), .browser(.newTab), .openURL(URL(string: "https://github.com")!),
        ])
    }

    func testSearchQueriesKeepTheirAnds() {
        XCTAssertEqual(plan("search for salt and pepper shakers"), [.searchHere("salt and pepper shakers")])
        XCTAssertEqual(plan("Search YouTube for lofi beats and chill music"), [.webSearch("lofi beats and chill music", .youtube)])
        XCTAssertEqual(plan("search for best laptops on amazon"), [.webSearch("best laptops", .amazon)])
        XCTAssertEqual(plan("Google this"), [.searchSelection(.google)])
    }

    func testAppsAndSites() {
        XCTAssertEqual(plan("Open VS Code"), [.openApp("Visual Studio Code")])
        XCTAssertEqual(plan("launch spotify please"), [.openApp("Spotify")])
        XCTAssertEqual(plan("Open YouTube."), [.openURL(URL(string: "https://www.youtube.com")!)])
        XCTAssertEqual(plan("go to the gmail website"), [.openURL(URL(string: "https://mail.google.com")!)])
        XCTAssertEqual(plan("open settings"), [.openApp("System Settings")])
        XCTAssertEqual(plan("Quit Slack"), [.quitApp("Slack")])
        XCTAssertEqual(plan("open crome"), [.openApp("Google Chrome")])
    }

    func testKeysAndTyping() {
        // "and press enter" is part of the writing request; the writing model turns it into a key press.
        XCTAssertEqual(plan("type hello world and press enter"), [.edit("type hello world and press enter")])
        XCTAssertNil(CommandParser.plainText("type hello world and press enter"))
        XCTAssertEqual(plan("press command shift T"), [.pressKeys(KeyCombo(key: "t", command: true, shift: true))])
        XCTAssertEqual(plan("copy that, then paste"), [.pressKeys(KeyCombo(key: "c", command: true)), .pressKeys(KeyCombo(key: "v", command: true))])
        XCTAssertEqual(plan("Click the sign in button"), [.click("sign in")])
    }

    func testSystem() {
        XCTAssertEqual(plan("set the volume to 30 percent"), [.system(.setVolume, 30)])
        XCTAssertEqual(plan("turn the volume up"), [.system(.volumeUp, nil)])
        XCTAssertEqual(plan("mute"), [.system(.mute, nil)])
        XCTAssertEqual(plan("next song"), [.system(.nextTrack, nil)])
        XCTAssertEqual(plan("turn on dark mode"), [.system(.darkModeOn, nil)])
        XCTAssertEqual(plan("scroll down a bit"), [.scroll(.down, .small)])
        XCTAssertEqual(plan("go to the top of the page"), [.scroll(.top, .large)])
        XCTAssertEqual(plan("lock the screen"), [.system(.lockScreen, nil)])
    }

    func testRemindersAndScheduling() {
        XCTAssertEqual(plan("remind me in 10 minutes to check the build"), [.schedule(after: 600, at: nil, task: "check the build", reminder: true)])
        XCTAssertEqual(plan("Remind me to call mom in two hours."), [.schedule(after: 7200, at: nil, task: "call mom", reminder: true)])
        XCTAssertEqual(plan("in 5 minutes, open chrome and search for cats"), [.schedule(after: 300, at: nil, task: "open chrome and search for cats", reminder: false)])
        XCTAssertEqual(plan("remind me at 5 pm to stretch"), [.schedule(after: nil, at: DateComponents(hour: 17, minute: 0), task: "stretch", reminder: true)])
        XCTAssertEqual(plan("set a timer for 3 minutes"), [.schedule(after: 180, at: nil, task: "Timer done", reminder: true)])
    }

    func testClaude() {
        XCTAssertEqual(plan("Tell Claude Code to run the tests and fix whatever fails."),
                       [.claude("run the tests and fix whatever fails")])
        XCTAssertEqual(plan("Tell Claude to open the readme and run it, then remind me in 10 minutes to check it."),
                       [.claude("open the readme and run it"), .schedule(after: 600, at: nil, task: "check it", reminder: true)])
    }

    func testUnknownGoesToAgent() {
        XCTAssertEqual(plan("Open Chrome and find me a cheap flight to Goa next Friday"),
                       [.openApp("Google Chrome"), .agent("find me a cheap flight to Goa next Friday")])
        XCTAssertEqual(plan("summarize this page"), [.agent("summarize this page")])
        XCTAssertEqual(plan("write an email to Priya saying I'm late"), [.agent("write an email to Priya saying I'm late")])
    }

    func testStreamingHoldsBackIncompleteTail() {
        let r = parser.streamingPlan("Open Chrome. Search for")
        XCTAssertEqual(r.ready, [.openApp("Google Chrome")])
        XCTAssertEqual(r.remainder, "Search for")
    }

    func testDurations() {
        XCTAssertEqual(Durations.parse("half an hour"), 1800)
        XCTAssertEqual(Durations.parse("ninety seconds"), 90)
        XCTAssertEqual(Durations.parse("twenty five minutes"), 1500)
        XCTAssertEqual(Durations.parseClock("5:30 p.m."), DateComponents(hour: 17, minute: 30))
    }
}

final class StreamingRegressionTests: XCTestCase {
    func testLeadingConnectorAfterPause() {
        let parser = CommandParser(apps: ["Google Chrome"])
        XCTAssertEqual(parser.plan("And search for the best. Ramen in Tokyo. Then turn the volume to 30%."),
                       [.searchHere("the best Ramen in Tokyo"), .system(.setVolume, 30)])
    }
}

final class RealUsageTests: XCTestCase {
    let parser = CommandParser(apps: ["Google Chrome", "Notes"])

    func testNotesFlowFromRealUse() {
        XCTAssertEqual(parser.plan("Open notes, create a new note and write in it, how are you doing?"), [
            .openApp("Notes"), .pressKeys(KeyCombo(key: "n", command: true)), .edit("write in it, how are you doing?"),
        ])
    }

    func testSearchResults() {
        XCTAssertEqual(parser.plan("Open Chrome, open a new tab, search for XYZ, open the first link"), [
            .openApp("Google Chrome"), .browser(.newTab), .searchHere("XYZ"), .openResult(1),
        ])
        XCTAssertEqual(parser.plan("click on the second result"), [.openResult(2)])
    }

    func testChat() {
        XCTAssertEqual(parser.plan("Hello? Hello?").count, 1)
        if case .say = parser.plan("What can you do?").first {} else { XCTFail("help should be instant") }
    }
}

final class SayTests: XCTestCase {
    func testSay() {
        XCTAssertEqual(CommandParser(apps: []).plan("say OK"), [.say("OK")])
    }
}

final class WatchTests: XCTestCase {
    let parser = CommandParser(apps: ["Notes", "Visual Studio Code", "Slack"])

    func testChangeHere() {
        XCTAssertEqual(parser.plan("If something changes here, click yes."),
                       [.watch(WatchSpec(scope: .here, text: nil, action: "click yes"))])
        XCTAssertEqual(parser.plan("Watch this area and whenever it changes alert me"),
                       [.watch(WatchSpec(scope: .here, text: nil, action: "alert me"))])
        XCTAssertEqual(parser.plan("When Claude asks for permission here, click yes"),
                       [.watch(WatchSpec(scope: .here, text: nil, action: "click yes"))])
    }

    func testTextInApp() {
        XCTAssertEqual(parser.plan("Whenever hello appears in Notes, say OK"),
                       [.watch(WatchSpec(scope: .app("Notes"), text: "hello", action: "say OK"))])
        XCTAssertEqual(parser.plan("In Notes, whenever I write hello, say OK"),
                       [.watch(WatchSpec(scope: .app("Notes"), text: "hello", action: "say OK"))])
        XCTAssertEqual(parser.plan("When I write urgent anywhere, alert me"),
                       [.watch(WatchSpec(scope: .anywhere, text: "urgent", action: "alert me"))])
    }

    func testStopAndNonWatch() {
        XCTAssertEqual(parser.plan("stop watching"), [.stopWatching])
        if case .watch = parser.plan("if it rains tomorrow remind me to take an umbrella").first { XCTFail("not a screen watch") }
    }
}

final class LightweightTests: XCTestCase {
    let parser = CommandParser(apps: ["Calendar", "Notes"])

    func testRecurringIsInstant() {
        XCTAssertEqual(parser.plan("Every day at 9am open gmail and my calendar"),
                       [.recurring(when: "every day at 9am", task: "open gmail and my calendar")])
        XCTAssertEqual(parser.plan("every 30 minutes, remind me to drink water").first,
                       .recurring(when: "every 30 minutes", task: "remind me to drink water"))
    }

    func testOpenList() {
        XCTAssertEqual(parser.plan("open gmail and my calendar"),
                       [.openURL(URL(string: "https://mail.google.com")!), .openApp("Calendar")])
    }
}

final class ContinuousTypingTests: XCTestCase {
    let parser = CommandParser(apps: ["Notes"])

    func testTypeInRunsImmediately() {
        XCTAssertEqual(parser.plan("Open notes. Type in hello, how are you?"), [.openApp("Notes"), .edit("Type in hello, how are you?")])
        let streamed = parser.streamingPlan("Type in hello, how are you?")
        XCTAssertEqual(streamed.ready, [.edit("Type in hello, how are you?")], "plain typing shouldn't wait for a pause")
        XCTAssertEqual(CommandParser.plainText("Type in hello, how are you?"), "hello, how are you?")
        // Might be an instruction: waits for the pause, then goes to the writing model.
        XCTAssertEqual(parser.streamingPlan("type heading as Introduction").ready, [])
        XCTAssertNil(CommandParser.plainText("type heading as Introduction"))
    }
}

final class WebsiteWatchTests: XCTestCase {
    func testWheneverIOpenWebsite() {
        let parser = CommandParser(apps: ["Google Chrome"])
        XCTAssertEqual(parser.plan("I am saying whenever I open this website, bejoyous.ai, remind me that this is a sensitive page.").last,
                       .watch(WatchSpec(scope: .anywhere, text: "bejoyous.ai", action: "remind me that this is a sensitive page")))
        XCTAssertEqual(parser.plan("Whenever I open bejoyous.ai, remind me that this is a sensitive page"),
                       [.watch(WatchSpec(scope: .anywhere, text: "bejoyous.ai", action: "remind me that this is a sensitive page"))])
    }
}

final class VocabularyTests: XCTestCase {
    let terms = ["bejoyous.ai", "Piyush", "Joyz", "Google Chrome", "Chrome", "Claude", "Spotify", "Notes"]

    func testFixesMisheardNames() {
        XCTAssertEqual(Vocabulary.correct("Open groom", terms: terms), "Open Chrome")
        XCTAssertEqual(Vocabulary.correct("Search bijoyus.i, read that page", terms: terms), "Search bejoyous.ai, read that page")
        XCTAssertEqual(Vocabulary.correct("Remind me to call Piush.", terms: terms), "Remind me to call Piyush.")
    }

    func testLeavesNormalWordsAlone() {
        let sentence = "Open the fourth link and see what is written on the screen"
        XCTAssertEqual(Vocabulary.correct(sentence, terms: terms), sentence)
        XCTAssertEqual(Vocabulary.correct("turn the volume down and play some music", terms: terms), "turn the volume down and play some music")
        XCTAssertEqual(Vocabulary.correct("tell me about clouds", terms: terms), "tell me about clouds")
    }
}

final class PausePunctuationTests: XCTestCase {
    func testPausesDontBreakCommands() {
        let parser = CommandParser(apps: ["Notes", "Google Chrome"])
        XCTAssertEqual(parser.plan("Open notes. Type in. Hello, how are you"), [.openApp("Notes"), .edit("Type in. Hello, how are you")])
        XCTAssertEqual(CommandParser.plainText("Type in. Hello, how are you"), "Hello, how are you")
        XCTAssertEqual(parser.plan("open groom"), [.openApp("Google Chrome")])
        XCTAssertEqual(parser.plan("Whenever I open this website, remind me that this is a sensitive page"),
                       [.watch(WatchSpec(scope: .anywhere, text: WatchSpec.currentSite, action: "remind me that this is a sensitive page"))])
    }
}

final class LiveStreamingTests: XCTestCase {
    func testSearchRunsAtThePause() {
        let parser = CommandParser(apps: ["Google Chrome"])
        XCTAssertEqual(parser.streamingPlan("Open Chrome. Search for the best ramen").ready,
                       [.openApp("Google Chrome"), .searchHere("the best ramen")])
        XCTAssertEqual(parser.streamingPlan("Search for").ready, [], "a bare verb waits for more")
        XCTAssertEqual(parser.streamingPlan("Search cats").ready, [], "one-word queries wait in case more is coming")
    }
}

final class SpokenEmailTests: XCTestCase {
    let known = ["a@joyz.ai", "joyz.ai", "bejoyous.ai", "Piyush"]

    func testUserRealTranscripts() {
        XCTAssertEqual(SpokenText.normalize("Write to A at the red joys dirty I", known: known), "Write to a@joyz.ai")
        XCTAssertEqual(SpokenText.normalize("E at the read geovisor.ai", known: known), "e@geovisor.ai")
    }

    func testCommonGarbles() {
        XCTAssertEqual(SpokenText.normalize("Write to or at the ratejoice.ie", known: known), "Write to a@joyz.ai")
        XCTAssertEqual(SpokenText.normalize("Send it to peosh at the rate gmail.com", known: known), "Send it to peosh@gmail.com")
        XCTAssertEqual(SpokenText.normalize("Type rahul.sharmar at the rateoutlook.com", known: known), "Type rahul.sharmar@outlook.com")
        XCTAssertEqual(SpokenText.normalize("mail ravi at the rate of gmail dot com please", known: known), "mail ravi@gmail.com please")
    }

    func testLeavesOrdinarySentencesAlone() {
        XCTAssertEqual(SpokenText.normalize("Meet me at the red door at 5", known: known), "Meet me at the red door at 5")
        XCTAssertEqual(SpokenText.normalize("look at the rate of inflation", known: known), "look at the rate of inflation")
    }
}

final class HoldSessionTests: XCTestCase {
    let parser = CommandParser(apps: ["Google Chrome"])

    func testGluedVerbsFromRealUse() {
        XCTAssertEqual(parser.plan("OpenGermany.google.com"), [.openURL(URL(string: "https://germany.google.com")!)])
        XCTAssertEqual(parser.plan("Opencloud.ai"), [.openURL(URL(string: "https://cloud.ai")!)])
    }

    func testUnknownClauseDoesNotBlockLaterCommands() {
        // The user moved on after "find me a cheap flight", so it goes to Claude now and "new tab" still runs.
        let r = parser.streamingPlan("Find me a cheap flight to Goa. Open a new tab")
        XCTAssertEqual(r.ready, [.agent("Find me a cheap flight to Goa"), .browser(.newTab)])
        XCTAssertEqual(parser.streamingPlan("Find me a cheap flight to Goa").ready, [], "the last clause may still be growing")
    }

    func testCloseIt() {
        XCTAssertEqual(parser.plan("Close it"), [.closeCurrent])
    }
}

final class SiteNameTests: XCTestCase {
    func testMisheardSitesFromRealUse() {
        XCTAssertEqual(SpokenText.normalize("Open Germany.google.com"), "Open gemini.google.com")
        XCTAssertEqual(SpokenText.normalize("open cloud.ai"), "open claude.ai")
        XCTAssertEqual(SpokenText.normalize("open gemini dot google dot com"), "open gemini.google.com")
        XCTAssertEqual(SpokenText.normalize("go to github.com"), "go to github.com")
        XCTAssertEqual(SpokenText.normalize("email a at the rate joyz dot ai", known: ["joyz.ai"]), "email a@joyz.ai")
    }
}

final class BenchmarkTranscriptTests: XCTestCase {
    func testParakeetOutputsFromBenchmark() {
        let parser = CommandParser(apps: ["Notes", "Screen Sharing"])
        XCTAssertEqual(parser.plan(SpokenText.normalize("Opencloud.ie")), [.openURL(URL(string: "https://claude.ai")!)])
        XCTAssertEqual(parser.plan(SpokenText.normalize("Opencloud.i")), [.openURL(URL(string: "https://claude.ai")!)])
        XCTAssertEqual(parser.plan(SpokenText.normalize("Open Gemini.google.com")), [.openURL(URL(string: "https://gemini.google.com")!)])
        XCTAssertEqual(SpokenText.normalize("Write to a at the ratejoice.ie", known: ["joyz.ai"]), "Write to a@joyz.ai")
        XCTAssertEqual(parser.plan("Tell claud code to run the tests and fix whatever fails"), [.claude("run the tests and fix whatever fails")])
    }
}

final class ApprovalTests: XCTestCase {
    func testApprovals() {
        XCTAssertEqual(HarkEngine.approval(in: "Yes"), .yes)
        XCTAssertEqual(HarkEngine.approval(in: "Uh, yes, apply, yes"), .yes)
        XCTAssertEqual(HarkEngine.approval(in: "Go ahead"), .yes)
        XCTAssertEqual(HarkEngine.approval(in: "No, don't"), .no)
        XCTAssertEqual(HarkEngine.approval(in: "Nope"), .no)
        XCTAssertEqual(HarkEngine.approval(in: "Yes, don't ask again"), .session)
        XCTAssertEqual(HarkEngine.approval(in: "Always approve"), .session)
        XCTAssertEqual(HarkEngine.approval(in: "No, don't ask again"), .no)
        XCTAssertNil(HarkEngine.approval(in: "Hmm, let me think"))
    }
}

final class SegmenterTests: XCTestCase {
    /// A phrase after a long silence must not carry that silence along (hands-free during long tasks).
    func testPhraseAfterLongSilenceStaysShort() async {
        let segmenter = Segmenter()
        var segments: [[Float]] = []
        let quiet = [Float](repeating: 0.0005, count: 1_600)
        for _ in 0..<600 { segments += await segmenter.append(quiet) }   // 60 s of near-silence
        let voice = (0..<16_000).map { Float(sin(Double($0) * 0.2) * 0.2) }  // 1 s "speech"
        segments += await segmenter.append(voice)
        for _ in 0..<10 { segments += await segmenter.append(quiet) }
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThan(segments.first?.count ?? .max, 16_000 * 2)
    }
}


final class SiteSearchTests: XCTestCase {
    /// Network: run with HARK_NETWORK_TESTS=1.
    func testFindsSitesOwnSearch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HARK_NETWORK_TESTS"] == "1")
        let youtube = await SiteSearch.shared.url(host: "www.youtube.com", query: "doomsday trailer")
        XCTAssertTrue(youtube?.absoluteString.hasPrefix("https://www.youtube.com/results?search_query=doomsday%20trailer") ?? false, youtube?.absoluteString ?? "nil")
        print("browser-learned site searches:", SiteSearch.browserSearches().count)
        let github = await SiteSearch.shared.url(host: "github.com", query: "swift actor")
        XCTAssertNotNil(github)
        print("github →", github?.absoluteString ?? "nil")
        let wiki = await SiteSearch.shared.url(host: "en.wikipedia.org", query: "Tokyo")
        print("wikipedia →", wiki?.absoluteString ?? "nil")
    }
}


final class NoiseTests: XCTestCase {
    /// Real transcripts of coughs, sniffles, and background speech from a session.
    func testSoundsThatArentRequests() {
        for heard in ["Mm.", "Uh", "Yeah", "Ah yeah", "Mm-hmm.", "Peace.", "Can I", "Okay.", "Yeah."] {
            XCTAssertTrue(CommandParser.isNoise(heard), heard)
        }
    }

    func testRealRequestsGetThrough() {
        for heard in ["What happened", "Delete all the watchers", "Message WhatsApp.", "close this one also.", "Explore this full page"] {
            XCTAssertFalse(CommandParser.isNoise(heard), heard)
        }
    }
}

final class WatcherLabelTests: XCTestCase {
    func testNumberedOptionsMatchTheirLabel() {
        for seen in ["1 Yes", "1. Yes", "❯ 1. Yes", "Yes", "1) Yes"] {
            XCTAssertEqual(ScreenText.normalizedLabel(seen), "yes", seen)
        }
        XCTAssertNotEqual(ScreenText.normalizedLabel("Yes, allow all edits during this session"), "yes")
    }
}

final class WritingTests: XCTestCase {
    let parser = CommandParser(apps: ["Notes", "Google Chrome"])

    /// Writing requests go whole to the writing model: it decides what's text and what's an instruction.
    func testTypingRequestsGoToTheWritingModel() {
        XCTAssertEqual(parser.plan("type heading as Introduction"), [.edit("type heading as Introduction")])
        XCTAssertEqual(parser.plan("type how are you, new paragraph, I'm fine"), [.edit("type how are you, new paragraph, I'm fine")])
        // An instant command after it still splits off.
        XCTAssertEqual(parser.plan("type hello. Then open Chrome").last, .openApp("Google Chrome"))
    }

    func testDictationModeCleanup() {
        XCTAssertEqual(CommandParser.dictation("How are you? New line. I'm fine, um, thanks"), "How are you?\nI'm fine, thanks")
        XCTAssertEqual(CommandParser.dictation("We need a new line of products"), "We need a new line of products")
    }

    func testPlanParsing() {
        let reply = #"{"ops":[{"op":"insert","text":"Introduction"},{"op":"format","style":"heading"}]}"#
        let plan = EditorBrain.plan(from: reply)
        XCTAssertEqual(plan.ops.count, 2)
        XCTAssertEqual(plan.ops[1]["style"] as? String, "heading")
    }
}

final class TextLocatingTests: XCTestCase {
    let text = "Meeting notes\nWe agreed on the budget. Next steps are unclear. The budget is fine."

    func testFindsQuotedTextNearestTheCaret() {
        let caret = (text as NSString).length
        let near = TextEditor.locate("budget", in: text, near: caret)
        XCTAssertEqual(near.map { (text as NSString).substring(with: $0) }, "budget")
        XCTAssertGreaterThan(near?.location ?? 0, 60, "the second 'budget' is nearer the end")
        XCTAssertLessThan(TextEditor.locate("budget", in: text, near: caret, occurrence: "first")?.location ?? 99, 50)
    }

    func testToleratesSpeechSpacingAndCase() {
        let found = TextEditor.locate("next steps are  unclear", in: text, near: 0)
        XCTAssertEqual(found.map { (text as NSString).substring(with: $0) }, "Next steps are unclear")
        XCTAssertNil(TextEditor.locate("not in the text", in: text, near: 0))
    }
}

final class TidyDeleteTests: XCTestCase {
    func testRemovingAWordLeavesCleanSpacing() {
        let text = "We agreed on the budget. Done"
        let ns = text as NSString
        let tidy = TextEditor.tidy(ns.range(of: "the budget"), in: text)
        XCTAssertEqual(ns.replacingCharacters(in: tidy, with: ""), "We agreed on. Done")
        let word = TextEditor.tidy(ns.range(of: "agreed"), in: text)
        XCTAssertEqual(ns.replacingCharacters(in: word, with: ""), "We on the budget. Done")
    }
}

final class StuckTypingTests: XCTestCase {
    /// Said while in writing mode in a real session; every one of these was typed instead of done.
    func testCommandsInsideSpeechAreFound() {
        let parser = CommandParser(apps: ["Google Chrome", "Notes"])
        for phrase in ["Okay. Open Chrome", "open YouTube here", "No open YouTube here", "Don't type but open the YouTube", "New tab"] {
            let clauses = parser.parse(phrase)
            print("•", phrase, "→", clauses.map { "\($0.text): \($0.command.map { "\($0)" } ?? "nil")" })
            XCTAssertTrue(clauses.contains { $0.command != nil }, phrase)
        }
    }
}
