import Foundation
import NaturalLanguage

public struct ParsedClause: Equatable, Sendable {
    public let text: String
    public let command: Command?
}

/// Turns speech into instant commands without a language model. Anything it can't parse is
/// handed to the agent, so it only needs to be right, never complete.
public struct CommandParser {
    public var resolveApp: (String) -> String?
    public var resolveExactApp: (String) -> String?

    public init(catalog: AppCatalog = .shared) {
        resolveApp = { catalog.resolve($0)?.name }
        resolveExactApp = { catalog.resolveExact($0)?.name }
    }

    /// For tests: resolve against a fixed list of app names.
    public init(apps: [String]) {
        self.init(catalog: AppCatalog(apps: apps.map { AppInfo(name: $0, url: URL(fileURLWithPath: "/Applications/\($0).app")) }))
    }

    // MARK: Planning

    /// Final pass: leading instant commands, then everything from the first unknown clause goes to the agent.
    public func plan(_ utterance: String) -> [Command] {
        let clauses = parse(utterance)
        var commands: [Command] = []
        for (index, clause) in clauses.enumerated() {
            if let command = clause.command {
                commands.append(command)
            } else {
                let rest = clauses[index...].map(\.text).joined(separator: ", ")
                commands.append(.agent(rest))
                break
            }
        }
        return commands
    }

    /// Streaming pass while the user is still talking: commands safe to run now, plus text to hold back.
    public func streamingPlan(_ text: String) -> (ready: [Command], remainder: String) {
        let clauses = parse(text)
        var ready: [Command] = []
        var index = 0
        while index < clauses.count {
            let isLast = index == clauses.count - 1
            guard let command = clauses[index].command else {
                // Not an instant command. If you've already moved on to the next command, it's complete:
                // more text to type, or a request for the brain, so it doesn't block everything after it.
                if isLast { break }
                ready.append(.agent(clauses[index].text))
                index += 1
                continue
            }
            if isLast && command.isOpenEnded && !Self.safeToRunEarly(command) { break }
            if case .stop = command { break }
            ready.append(command)
            index += 1
        }
        let remainder = clauses[index...].map(\.text).joined(separator: ", ")
        return (ready, remainder)
    }

    /// Open-ended commands that can run at a pause because a continuation can refine them
    /// ("search for best ramen" … "in Tokyo" re-runs the search with the full query).
    static func safeToRunEarly(_ command: Command) -> Bool {
        // Plain words to type go in the moment the phrase is heard; anything that might be an instruction waits.
        if case .edit(let request) = command { return plainText(request) != nil }
        if case .webSearch(let query, _) = command { return query.split(separator: " ").count >= 2 }
        if case .searchHere(let query) = command { return query.split(separator: " ").count >= 2 }
        return false
    }

    // MARK: Clause splitting

    static let strongVerbs: Set<String> = [
        "open", "launch", "start", "close", "quit", "exit", "search", "google", "type", "dictate", "write",
        "press", "hit", "click", "tap", "scroll", "go", "switch", "take", "lock", "mute", "unmute", "play",
        "pause", "resume", "remind", "tell", "ask", "download", "reload", "refresh", "set", "turn", "wait",
        "copy", "paste", "undo", "redo", "select", "show", "hide", "minimize", "minimise", "enable", "disable",
        "look", "read", "send", "create", "make", "save", "increase", "decrease", "raise", "lower", "skip",
        "find", "reopen", "navigate", "summarize", "check", "put", "move", "delete", "rename", "run",
        "schedule", "youtube", "zoom", "maximize", "bring", "fire", "visit", "cut", "lookup",
    ]
    static let weakStarters: Set<String> = ["new", "next", "previous", "volume", "back", "forward", "dark",
                                            "light", "screenshot", "enter", "escape", "return", "what", "what's"]
    static let connectors: Set<String> = ["and", "then", "also", "now", "after", "that", "next,", "finally", "please", "and,", "then,"]

    public func parse(_ utterance: String) -> [ParsedClause] {
        let cleaned = Self.normalize(utterance)
        let words = cleaned.split(separator: " ").map(String.init)
        var clauses: [[String]] = [[]]
        var i = 0
        while i < words.count {
            let word = words[i]
            let lower = word.lowercased()
            let endsSentence = word.last.map { ",.;!?".contains($0) } ?? false
            let bareConnector = Self.connectors.contains(lower.trimmingCharacters(in: .punctuationCharacters))
            if bareConnector, clauses[clauses.count - 1].isEmpty {
                i += 1  // "And search for…" left over from a pause
                continue
            }
            let isConnector = bareConnector

            if endsSentence || isConnector {
                // Look past connector words to see whether a new command starts here.
                var j = endsSentence ? i + 1 : i
                while j < words.count, Self.connectors.contains(words[j].lowercased().trimmingCharacters(in: .punctuationCharacters)) { j += 1 }
                let current = (clauses[clauses.count - 1] + [word]).joined(separator: " ")
                let split: Bool
                switch Self.swallowKind(current) {
                case .everything: split = false
                case .untilInstantCommand: split = endsSentence && j < words.count && isInstantContinuation(Array(words[j...]))
                case nil: split = j < words.count && shouldSplit(before: Array(words[j...]))
                }
                if split {
                    if endsSentence { clauses[clauses.count - 1].append(String(word.dropLast())) }
                    clauses.append([])
                    i = j
                    continue
                }
            }
            clauses[clauses.count - 1].append(word)
            i += 1
        }
        return clauses
            .map { $0.joined(separator: " ").trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",;"))) }
            .filter { !$0.isEmpty && !Self.connectors.contains($0.lowercased()) }
            .flatMap(expandOpenList)
            .map { ParsedClause(text: $0, command: parseClause($0)) }
    }

    /// "open Gmail and my calendar" → "open Gmail", "open my calendar" when every part is openable.
    private func expandOpenList(_ clause: String) -> [String] {
        guard let m = clause.firstMatch(#"^((?i:open|launch|start)) (.+)$"#) else { return [clause] }
        let parts = m[2].components(separatedBy: CharacterSet(charactersIn: ",")).flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return [clause] }
        let opens = parts.map { "\(m[1]) \($0)" }
        return opens.allSatisfy({ parseClause($0) != nil }) ? opens : [clause]
    }

    enum Swallow { case everything, untilInstantCommand }

    /// Clauses whose argument is free-form speech keep the rest of the utterance.
    static func swallowKind(_ clause: String) -> Swallow? {
        let l = clause.lowercased()
        if l.matches(#"^(?:in|after) (?:\S+ ){0,3}(?:seconds?|minutes?|hours?|mins?)\b"#) || l.matches(#"^at \d"#)
            || l.matches(#"^(?:every|daily|each day)\b"#)
            || l.hasPrefix("remind me") || l.matches(#"^(?:set|start) (?:a |an )?(?:timer|reminder)"#) {
            return .everything
        }
        if l.matches(#"^(?:(?:watch|monitor|keep an eye on|track|in|on|inside)\b[^,]{0,40}[, ]+(?:and )?)?(?:when|whenever|if|once|as soon as)\b"#) {
            return .everything
        }
        if l.matches(#"^(?:tell|ask|have|get) (?:claude|cloud|claud)\b"#) || l.matches(#"^(?:claude|claud) code\b"#) {
            return .untilInstantCommand
        }
        // "type how are you, new paragraph, I'm fine" is one request for the writing model.
        if l.matches(#"^(?:type|write|dictate)\b"#) { return .untilInstantCommand }
        return nil
    }

    /// After a Claude prompt, only clearly-Hark commands ("then remind me…", "then open Chrome") split off.
    private func isInstantContinuation(_ rest: [String]) -> Bool {
        var phrase: [String] = []
        for word in rest {
            phrase.append(word)
            if word.last.map({ ",.;!?".contains($0) }) ?? false { break }
        }
        switch parseClause(phrase.joined(separator: " ")) {
        case .schedule, .openApp, .webSearch, .browser, .system, .openURL, .tellTime: return true
        default: return false
        }
    }

    private func shouldSplit(before rest: [String]) -> Bool {
        guard let first = rest.first?.lowercased().trimmingCharacters(in: .punctuationCharacters) else { return false }
        if Self.strongVerbs.contains(first) { return true }
        if Self.weakStarters.contains(first) {
            var phrase: [String] = []
            for word in rest.prefix(8) {
                if !phrase.isEmpty, Self.connectors.contains(word.lowercased()) { break }
                phrase.append(word)
                if word.last.map({ ",.;!?".contains($0) }) ?? false { break }
            }
            return parseClause(phrase.joined(separator: " ")) != nil
        }
        return false
    }

    static func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\n", with: " ")
        let replacements: [(String, String)] = [
            (" dot com", ".com"), (" dot org", ".org"), (" dot io", ".io"), (" dot ai", ".ai"), (" dot net", ".net"),
            (" dot in", ".in"), (" dot dev", ".dev"), (" dot co", ".co"), ("’", "'"),
        ]
        for (from, to) in replacements { s = s.replacingOccurrences(of: from, with: to, options: .caseInsensitive) }
        // The speech model sometimes glues a verb to the next word: "OpenGermany.google.com", "Opencloud.ai".
        s = SpokenText.unglue(s)
        s = s.split(separator: " ").joined(separator: " ")
        var lower = s.lowercased()
        let fillers = ["hey hark,", "hey hark", "hark,", "okay,", "okay ", "ok,", "ok ", "so,", "um,", "uh,", "um ", "uh ",
                       "please ", "can you ", "could you ", "would you ", "will you ", "i want you to ", "i'd like you to ",
                       "go ahead and ", "just ", "i am saying ", "i'm saying ", "i said ", "i mean ", "what i mean is ",
                       "basically ", "so basically ", "listen ", "listen, ", "actually ", "actually, ", "now ", "and "]
        // Corrections lead with what not to do: "no, open YouTube", "don't type but open the YouTube" → the request.
        s = s.replacingOccurrences(of: #"^(?i:(?:no|nope|nah|wait|sorry|not that|not this)[,.!]?\s+(?:no[,.!]?\s+)*|(?:don'?t|do not)\s+(?:\w+\s+){0,3}?(?:but|just)[,]?\s+|i said[,]?\s+)"#,
                                   with: "", options: .regularExpression)
        lower = s.lowercased()
        var changed = true
        while changed {
            changed = false
            for filler in fillers where lower.hasPrefix(filler) {
                s = String(s.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
                lower = s.lowercased()
                changed = true
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Clause grammar

    public func parseClause(_ raw: String) -> Command? {
        let original = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".!?,;")))
        var l = original.lowercased()
        for suffix in [" please", " for me", " now", " right now", " thanks", " thank you"] where l.hasSuffix(suffix) {
            l.removeLast(suffix.count)
        }
        l = l.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        guard !l.isEmpty else { return nil }
        let o = String(original.prefix(l.count))

        if let c = parseWatch(l, o) { return c }
        if let c = parseControl(l) { return c }
        if let c = parseChat(l, o) { return c }
        if let c = parseResult(l) { return c }
        if let c = parseClaude(l, o) { return c }
        if let c = parseSchedule(l, o) { return c }
        let withPunctuation = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",;")))
        if let c = parseTyping(l, withPunctuation) { return c }
        if let c = parseNewItem(l) { return c }
        if let c = parseBrowser(l) { return c }
        if let c = parseScroll(l) { return c }
        if let c = parseSystem(l) { return c }
        if let c = parseSearch(l, o) { return c }
        if let c = parseKeys(l) { return c }
        if let c = parseWindow(l) { return c }
        if let c = parseQuit(l) { return c }
        if let c = parseOpen(l, o) { return c }
        if let c = parseClick(l, o) { return c }
        return nil
    }

    private func parseControl(_ l: String) -> Command? {
        if ["stop", "cancel", "never mind", "nevermind", "shut up", "be quiet", "stop talking", "that's all", "forget it"].contains(l) { return .stop }
        if ["what time is it", "what's the time", "tell me the time", "what is the time", "time"].contains(l) { return .tellTime }
        if ["what's the date", "what is the date", "what day is it", "what's today's date", "what is today's date", "today's date", "what's today"].contains(l) { return .tellDate }
        if let m = l.firstMatch(#"^wait(?: for)?(?: about)? (.+?) (seconds?|minutes?)$"#), let n = NumberWords.parse(m[1]) {
            return .wait(Double(n) * (m[2].hasPrefix("minute") ? 60 : 1))
        }
        if ["wait", "wait a second", "wait a sec", "hold on", "one second", "wait a moment"].contains(l) { return .wait(2) }
        if l.matches(#"^download (this|it|that|this file|the file|this page|the page|this pdf|the pdf|this image|this video)$"#) { return .downloadCurrent }
        return nil
    }

    private func parseClaude(_ l: String, _ o: String) -> Command? {
        if let m = o.firstMatch(#"^(?i:(?:tell|ask|have|get) (?:claude|cloud|claud)(?: code)?,?(?: to)? )(.+)$"#) { return .claude(m[1]) }
        if let m = o.firstMatch(#"^(?i:(?:claude|claud) code[,:]? )(.+)$"#) { return .claude(m[1]) }
        return nil
    }

    private func parseSchedule(_ l: String, _ o: String) -> Command? {
        // "remind me in 10 minutes to call mom" / "remind me to call mom in 10 minutes" / "remind me at 5 pm to ..."
        if let m = o.firstMatch(#"^(?i:remind me (?:in|after) )(.+?) (?i:to|that|about) (.+)$"#), let d = Durations.parse(m[1]) {
            return .schedule(after: d, at: nil, task: m[2], reminder: true)
        }
        if let m = o.firstMatch(#"^(?i:remind me (?:to|that|about) )(.+) (?i:in|after) (.+)$"#), let d = Durations.parse(m[2]) {
            return .schedule(after: d, at: nil, task: m[1], reminder: true)
        }
        if let m = o.firstMatch(#"^(?i:remind me at )(.+?) (?i:to|that|about) (.+)$"#), let t = Durations.parseClock(m[1]) {
            return .schedule(after: nil, at: t, task: m[2], reminder: true)
        }
        if let m = o.firstMatch(#"^(?i:remind me (?:to|that|about) )(.+) (?i:at) (.+)$"#), let t = Durations.parseClock(m[2]) {
            return .schedule(after: nil, at: t, task: m[1], reminder: true)
        }
        if let m = l.firstMatch(#"^(?:set|start) (?:a |an )?(?:timer|reminder) for (.+?)(?: (?:to|for|that) (.+))?$"#), let d = Durations.parse(m[1]) {
            return .schedule(after: d, at: nil, task: m[2].isEmpty ? "Timer done" : m[2], reminder: true)
        }
        // "every day at 9am open gmail" / "every 30 minutes check my mail"
        if let m = o.firstMatch(#"^((?i:every (?:day|morning|evening|weekday)|daily|each day) (?i:at) \d{1,2}(?::\d{2})? ?(?i:[ap]\.?m\.?)?)[,]? (.+)$"#) {
            return .recurring(when: m[1].lowercased().replacingOccurrences(of: "every morning", with: "every day").replacingOccurrences(of: "every evening", with: "every day"), task: m[2])
        }
        if let m = o.firstMatch(#"^((?i:every) (?:\d+|[a-z]+)? ?(?i:seconds?|minutes?|mins?|hours?))[,]? (.+)$"#) {
            return .recurring(when: m[1].lowercased(), task: m[2])
        }
        // "in 10 minutes, open chrome" → run a command later
        if let m = o.firstMatch(#"^(?i:in|after) (.+?(?:seconds?|minutes?|hours?|mins?|secs?))[,]? (.+)$"#), let d = Durations.parse(m[1]) {
            return .schedule(after: d, at: nil, task: m[2], reminder: false)
        }
        if let m = o.firstMatch(#"^(?i:at) (\d{1,2}(?::\d{2})? ?(?i:[ap]\.?m\.?)?)[,]? (.+)$"#), let t = Durations.parseClock(m[1]) {
            return .schedule(after: nil, at: t, task: m[2], reminder: false)
        }
        return nil
    }

    private func parseChat(_ l: String, _ o: String) -> Command? {
        let bare = l.replacingOccurrences(of: #"[^a-z' ]"#, with: "", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        if bare.matches(#"^(?:(?:hello|hey|hi|yo|hark|hey there)\s*)+$"#) || ["are you there", "you there", "can you hear me", "are you listening"].contains(bare) {
            return .say("I'm here. Hold Option Command and tell me what to do.")
        }
        if ["who are you", "what are you", "what's your name", "what is your name", "introduce yourself", "how are you", "how are you doing"].contains(bare) {
            return .say(bare.hasPrefix("how") ? "All good, and ready. What should I do?" : "I'm Hark, your Mac's voice. Hold Option Command and tell me what to do.")
        }
        if ["what can you do", "help", "what can i say", "what can i ask you", "how do i use you", "what do you do"].contains(bare) {
            return .say("I can open apps and websites, search, type, click, control your Mac, set reminders and automations, and send work to Claude Code. Anything else, just ask.")
        }
        if let m = o.firstMatch(#"^(?i:say|speak)(?i: out loud)? [\"“']?(.+?)[\"”']?$"#) { return .say(m[1].prefix(1).uppercased() + m[1].dropFirst()) }
        if ["thank you", "thanks", "thanks a lot", "thank you so much", "great thanks", "perfect thanks"].contains(bare) {
            return .say("Anytime.")
        }
        return nil
    }

    static let watchActionVerbs = "click|press|tap|hit|alert|notify|tell|let|say|ping|open|type|run|remind|take|send|approve|accept|select|close|play|mute|show|beep|warn|speak|write|search|lock|pause|stop|scroll|download"

    /// "If something changes here, click yes" · "Whenever hello appears in Notes, say OK" · "When I write urgent anywhere, alert me".
    private func parseWatch(_ l: String, _ o: String) -> Command? {
        if l.matches(#"^(?:stop|cancel|quit) (?:watching|monitoring)\b"#) || l == "stop all watchers" { return .stopWatching }
        guard let head = o.firstMatch("^(?i:(?:(?:watch|monitor|keep an eye on|track|in|on|inside) (.+?)[,]? (?:and )?)?(?:when|whenever|if|once|as soon as)(?:ever)?) (.+)$") else {
            return nil
        }
        let target = head[1].lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let words = head[2].split(separator: " ").map(String.init)
        let verbs = Set(Self.watchActionVerbs.split(separator: "|").map(String.init))
        // "When I write hello, type world": try each action verb as the split until the condition makes sense.
        for i in 1..<max(words.count, 1) {
            guard verbs.contains(words[i].lowercased().trimmingCharacters(in: .punctuationCharacters)) else { continue }
            var conditionWords = Array(words[..<i])
            while let last = conditionWords.last, ["then", "please", "just", "and"].contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                conditionWords.removeLast()
            }
            let condition = conditionWords.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            let action = words[i...].joined(separator: " ").trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".!")))
            if let spec = watchSpec(target: target, condition: condition, action: action) { return .watch(spec) }
        }
        return nil
    }

    private func watchSpec(target: String, condition: String, action: String) -> WatchSpec? {
        let c = condition.lowercased()
        // "whenever I open bejoyous.ai" → watch for that address wherever it shows up (browser tab, address bar).
        if let site = c.firstMatch(#"^(?:i |you )?(?:open|visit|go to|am on|land on|load)(?: (?:this|the|that) (?:website|site|page|url))?[,:.]? ?(?:https?://)?(?:www\.)?([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})"#) {
            return WatchSpec(scope: .anywhere, text: site[1], action: action)
        }
        // "whenever I open this website" → whatever site is in front right now.
        if c.matches(#"^(?:i |you )?(?:open|visit|go to|am on|land on|load) (?:this|the current|the same|that) (?:website|site|page|web ?page)\b"#) {
            return WatchSpec(scope: .anywhere, text: WatchSpec.currentSite, action: action)
        }
        let trailing = #"(?:\s+(?i:anywhere|here|there|on (?:the |my )?screen|in .+|on .+|inside .+))?$"#
        var text: String?
        if let t = condition.firstMatch(#"^(?i:i (?:write|type|enter)|someone (?:writes|types|sends)|you see|it says|(?:the )?(?:text|word|words))\s+[\"“']?(.+?)[\"”']?"# + trailing) {
            text = t[1]
        } else if let t = condition.firstMatch(#"^[\"“']?(.+?)[\"”']?\s+(?i:appears|shows up|pops up|comes up|is written|is typed|is shown|is displayed|gets written)"# + trailing) {
            text = t[1]
        }
        if let t = text, ["something", "anything", "it", "this", "that", "a message", "a prompt", "a popup"].contains(t.lowercased()) { text = nil }
        let isChange = text == nil && c.matches(#"\b(?:changes?|changed|updates?|updated|is different|moves?|asks?|prompts?|pops? up|appears?|shows? up|finishes|is done|completes)\b"#)
        guard text != nil || isChange else { return nil }

        let scopeText = target + " " + c
        let scope: WatchSpec.Scope
        if scopeText.matches(#"\b(?:anywhere|on (?:the |my )?screen|any app)\b"#) {
            scope = .anywhere
        } else if let inApp = c.firstMatch(#"\b(?:in|on|inside) (?:the |my )?([a-z0-9 .]+?)(?: app| window)?$"#), let app = resolveApp(inApp[1]) {
            scope = .app(app)
        } else if !target.isEmpty, !target.matches(#"\b(?:here|this|that|there)\b"#), let app = resolveApp(target) {
            scope = .app(app)
        } else if scopeText.matches(#"\b(?:here|this|that|there)\b"#) || text == nil {
            scope = .here
        } else {
            scope = .anywhere
        }
        return WatchSpec(scope: scope, text: text, action: action)
    }

    static let ordinals: [String: Int] = [
        "first": 1, "1st": 1, "top": 1, "one": 1, "second": 2, "2nd": 2, "two": 2, "third": 3, "3rd": 3, "three": 3,
        "fourth": 4, "4th": 4, "four": 4, "fifth": 5, "5th": 5, "five": 5,
    ]

    private func parseResult(_ l: String) -> Command? {
        let ord = Self.ordinals.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        if let m = l.firstMatch("^(?:open|click|click on|go to|visit|select|tap|tap on|choose|show me)(?: the)? (\(ord))(?: search)? (?:result|link|website|site|one|hit|search result)$"),
           let n = Self.ordinals[m[1]] {
            return .openResult(n)
        }
        if let m = l.firstMatch("^(?:open|click|click on|go to)(?: the)? (?:result|link) (?:number )?(\\d|\(ord))$"),
           let n = Int(m[1]) ?? Self.ordinals[m[1]] {
            return .openResult(n)
        }
        return nil
    }

    private func parseNewItem(_ l: String) -> Command? {
        if l.matches(#"^(?:create|make|start|open|add|begin|write)(?: me)?(?: a| an)? new (?:note|document|doc|file|email|mail|message|draft|event|reminder|sheet|spreadsheet|page|chat|conversation|project)$"#)
            || ["new note", "new document", "new email", "new message", "new file"].contains(l) {
            return .pressKeys(KeyCombo(key: "n", command: true))
        }
        if l.matches(#"^(?:create|make|add)(?: a)? new folder$"#) || l == "new folder" {
            return .pressKeys(KeyCombo(key: "n", command: true, shift: true))
        }
        return nil
    }

    private func parseTyping(_ l: String, _ o: String) -> Command? {
        var text: String?
        if let m = o.firstMatch(#"^(?i:type in|type into|type out|type|dictate|write down|enter the text|enter)[.:,]? (.+)$"#) { text = m[1] }
        // "write in it …" / "write down …" is dictation; other "write …" ("write to a@x.com", "write the subject as …")
        // needs to see the screen, so it goes to Claude.
        if text == nil, l.matches(#"^write (?:in it|into it|in there|in here|there|here|down|this)\b"#) {
            text = String(o.dropFirst(6))
        }
        guard let typed = text?.trimmingCharacters(in: CharacterSet(charactersIn: ".,:; ")), !typed.isEmpty else { return nil }
        // What to write and how ("type heading as Introduction", "write thanks in bold") is the writing model's call:
        // it gets the whole request, words like "type" and "in it" included.
        return .edit(o.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Dictation

    /// "go to a new paragraph", "in the next line", "create a new line" — where the text goes, not what it says.
    static let breakLead = #"(?:(?:go|move|jump|skip)\s+to|start|create|make|add|insert|begin|put|open|in|on|onto)\s+(?:a\s+|an\s+|the\s+)?"#
    static let breakUnit = #"(?:new|next|another|fresh)\s+(line|paragraph)"#
    static let fillerWords = #"\b(?:uh+|um+|erm|uhm)\b[,.]?\s*"#

    /// Cleans typed speech: line/paragraph instructions become breaks, "uh"/"um" disappear, "start typing" cues go.
    /// A bare "new line" only counts as its own sentence, so "a new line of products" stays text.
    public static func dictation(_ text: String) -> String {
        var s = text.replacingOccurrences(of: fillerWords, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"(?i)\b(?:start|keep|continue|resume)\s+typing\b[,.]?\s*"#, with: "", options: .regularExpression)
        let patterns = [
            "(?i)[,.;:!?]?\\s*\\b" + breakLead + breakUnit + "\\b[,.;:!?]?\\s*",
            "(?i)(?:^|(?<=[,.;:!?]))\\s*" + breakUnit + "\\s*(?:[,.;:!?]\\s*|$)",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = s as NSString
            var out = ""
            var cursor = 0
            for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                out += ns.substring(with: match.range(at: 1)).lowercased() == "paragraph" ? "\n\n" : "\n"
                cursor = match.range.location + match.range.length
            }
            s = out + ns.substring(from: cursor)
        }
        // "how are you. Now,\n" → "how are you.\n"; no stray spaces around breaks.
        s = s.replacingOccurrences(of: #"(?i)[ \t]*\b(?:now|then|and|okay|so)[,.]?[ \t]*(?=\n)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,;:]?[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Not a request: a cough or sniffle comes out of the speech model as "Mm." or "Uh", a "yeah" or "mm-hmm" is you
    /// talking to someone else, and background chatter arrives as stray fragments ("Peace.", "Can I").
    static let backchannel: Set<String> = ["uh", "uhh", "um", "umm", "uhm", "erm", "mm", "mmm", "hmm", "hm", "mhm", "mm-hmm", "uh-huh",
                                           "hmm-hmm", "ah", "oh", "eh", "huh", "yeah", "yep", "yup", "ya", "yes", "no", "nope", "okay", "ok",
                                           "right", "sure", "hey", "hi", "hello", "wow", "oops", "peace", "bye", "thanks", "cool", "nice",
                                           "alright", "so", "well"]

    /// Only fillers ("uh", "mm-hmm", "okay"). While you're writing, short real words ("are you okay") are content.
    public static func isFiller(_ text: String) -> Bool {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { !$0.isEmpty }
        return words.allSatisfy(backchannel.contains)
    }

    public static func isNoise(_ text: String) -> Bool {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { !$0.isEmpty }
        guard words.count > 1 else { return true }
        if words.allSatisfy(Self.backchannel.contains) { return true }
        guard words.count <= 3 else { return false }
        // A short fragment needs something to act on: a real verb, noun, adjective, or number — not "can", "is", "I".
        let auxiliaries: Set<String> = ["can", "could", "would", "should", "will", "shall", "may", "might", "must", "do", "does", "did",
                                        "is", "am", "are", "was", "were", "be", "been", "have", "has", "had", "let", "let's"]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        let sentence = words.joined(separator: " ")
        tagger.string = sentence
        var content = false
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = String(sentence[range])
            if [.noun, .verb, .adjective, .number].contains(tag), !auxiliaries.contains(word), !Self.backchannel.contains(word) { content = true; return false }
            return true
        }
        return !content
    }

    /// The words to type when a writing request is plainly just words: "type hello, how are you" → "hello, how are
    /// you", or (while writing) "see you at six" → itself. Nil whenever any word could be an instruction about layout,
    /// formatting, position, or editing ("heading as", "in bold", "new line", "delete", "instead") — the writing
    /// model decides those. This only picks the instant path; it never decides what an instruction means.
    public static func plainText(_ request: String) -> String? {
        // Only an explicit "type …" is typed without asking the model. Speech that just follows ("next item",
        // "in the next line") could be an instruction in any wording, so the model decides that.
        guard let rest = typedPart(request) else { return nil }
        let text = dictation(rest)
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        let words = Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        return words.isDisjoint(with: instructionWords) ? text : nil
    }

    /// What comes after an explicit "type …" / "write …", or nil without one.
    static func typedPart(_ request: String) -> String? {
        guard let m = request.trimmingCharacters(in: .whitespacesAndNewlines)
            .firstMatch(#"^(?i:type in|type into|type out|type|dictate|write down|write in it|write into it|write in there|write here|write)[.:,]?\s+(.+)$"#) else { return nil }
        // "type here: hello" → "hello"; "type this is great" keeps "this", "type there are three" keeps "there".
        return m[1].replacingOccurrences(of: #"^(?i:in it|into it|in there|in here|here)\s*[,:]?\s+|^(?i:there|this)\s*[,:]\s*"#, with: "", options: .regularExpression)
    }

    /// Words that can turn a sentence into an instruction about the text. Broad on purpose.
    static let instructionWords: Set<String> = [
        "heading", "headings", "title", "subtitle", "subheading", "bold", "italic", "italics", "underline", "underlined",
        "strikethrough", "bullet", "bullets", "bulleted", "list", "numbered", "checklist", "checkbox", "paragraph",
        "paragraphs", "line", "lines", "newline", "cursor", "caret", "select", "selection", "highlight", "delete", "remove",
        "erase", "cut", "copy", "paste", "replace", "undo", "redo", "capital", "capitalize", "caps", "uppercase", "lowercase",
        "font", "format", "formatting", "indent", "tab", "space", "spaces", "comma", "period", "colon", "semicolon", "quote",
        "quotes", "bracket", "brackets", "parenthesis", "emoji", "above", "below", "beginning", "previous", "word", "words",
        "sentence", "sentences", "letter", "character", "as", "instead", "into", "press", "enter", "return", "hit", "key",
        "search", "google", "find", "move", "go", "put", "insert", "add", "change", "fix", "correct", "make", "rewrite",
        "translate", "summarize", "shorter", "longer", "formal", "bigger", "smaller",
    ]

    /// A phrase cut off at "create a" / "go to the" isn't finished; wait for the rest before acting on it.
    public static func endsMidThought(_ text: String) -> Bool {
        let last = text.lowercased().trimmingCharacters(in: .whitespaces).split(separator: " ").last.map(String.init) ?? ""
        return ["a", "an", "the", "to", "into", "onto", "in", "on", "of", "for", "with", "at", "from", "my", "your", "our",
                "this", "that", "and", "or", "go", "create", "make", "add", "insert", "open", "search", "type"].contains(last)
    }

    private func parseBrowser(_ l: String) -> Command? {
        let t = l.replacingOccurrences(of: #"^(?:open|create|make|start|give me|bring up|launch)(?: up)? "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:a|an|another) "#, with: "", options: .regularExpression)
        switch t {
        case "new tab", "tab", "blank tab", "new browser tab", "new chrome tab", "new tab in chrome": return .browser(.newTab)
        case "new window", "new browser window", "new chrome window": return .browser(.newWindow)
        case "incognito window", "incognito tab", "private window", "private tab", "new incognito window",
             "new incognito tab", "new private window", "incognito": return .browser(.incognito)
        default: break
        }
        if l.matches(#"^close (?:this |the |current |that )?tab$"#) { return .browser(.closeTab) }
        if l.matches(#"^(?:go )?back(?: a page| to the previous page)?$"#) || l == "previous page" { return .browser(.back) }
        if l.matches(#"^(?:go )?forward(?: a page)?$"#) || l == "next page" { return .browser(.forward) }
        if l.matches(#"^(?:reload|refresh)(?: the| this)?(?: page| tab| website| site)?$"#) { return .browser(.reload) }
        if l.matches(#"^(?:go to |switch to )?(?:the )?next tab$"#) { return .browser(.nextTab) }
        if l.matches(#"^(?:go to |switch to )?(?:the )?(?:previous|last) tab$"#) { return .browser(.previousTab) }
        if l.matches(#"^(?:re-?open|restore|bring back)(?: the)?(?: last| closed| last closed)? tab$"#) { return .browser(.reopenTab) }
        return nil
    }

    private func parseScroll(_ l: String) -> Command? {
        if let m = l.firstMatch(#"^scroll(?: the page| this page| it)? (down|up|left|right)(?: (a bit|a little|a lot|more|all the way|way down|way up|slightly))?$"#) {
            let amount: ScrollAmount = ["a lot", "more", "all the way", "way down", "way up"].contains(m[2]) ? .large
                : (["a bit", "a little", "slightly"].contains(m[2]) ? .small : .medium)
            return .scroll(ScrollDirection(rawValue: m[1])!, amount)
        }
        if let m = l.firstMatch(#"^(?:scroll|go|jump|take me)(?: all the way)? (?:to|up to|down to) (?:the )?(top|bottom|end|beginning|start)(?: of the page)?$"#) {
            return .scroll(["top", "beginning", "start"].contains(m[1]) ? .top : .bottom, .large)
        }
        if l == "page down" { return .scroll(.down, .large) }
        if l == "page up" { return .scroll(.up, .large) }
        return nil
    }

    private func parseSystem(_ l: String) -> Command? {
        if let m = l.firstMatch(#"^(?:set|change|put|turn)? ?(?:the )?(?:volume|sound) (?:to|at) (\d{1,3})(?: ?%| percent)?$"#), let n = Int(m[1]) {
            return .system(.setVolume, min(100, n))
        }
        if l.matches(#"^(?:max(?:imum)?|full) volume$"#) || l.matches(#"^(?:turn|crank) (?:the )?volume all the way up$"#) { return .system(.setVolume, 100) }
        if l.matches(#"^(?:turn |set )?(?:the )?(?:volume|sound) up$"#) || l.matches(#"^(?:increase|raise|turn up)(?: the)? (?:volume|sound)$"#) || l == "louder" { return .system(.volumeUp, nil) }
        if l.matches(#"^(?:turn |set )?(?:the )?(?:volume|sound) down$"#) || l.matches(#"^(?:decrease|lower|reduce|turn down)(?: the)? (?:volume|sound)$"#) || ["quieter", "softer"].contains(l) { return .system(.volumeDown, nil) }
        if l.matches(#"^mute(?: the)?(?: sound| audio| volume| mac| computer| speakers)?$"#) { return .system(.mute, nil) }
        if l.matches(#"^unmute(?: the)?(?: sound| audio| volume| mac| computer| speakers)?$"#) { return .system(.unmute, nil) }
        if l.matches(#"^(?:pause|stop)(?: the)? (?:music|song|playback|video|track|audio|podcast)$"#) || l == "pause" { return .system(.pause, nil) }
        if l.matches(#"^(?:play|resume|continue)(?: the)?(?: music| song| playback| video| track| audio| podcast)?$"#) { return .system(.play, nil) }
        if l.matches(#"^(?:next|skip)(?: the)?(?: song| track| this song| this track)?$"#) || l == "skip this" { return .system(.nextTrack, nil) }
        if l.matches(#"^(?:previous|last|go back a)(?: song| track)$"#) { return .system(.previousTrack, nil) }
        if l.matches(#"^lock(?: the| my)?(?: screen| mac| computer| laptop)?$"#) { return .system(.lockScreen, nil) }
        if l.matches(#"^(?:sleep|turn off)(?: the)? (?:display|screen|monitor)$"#) { return .system(.sleepDisplay, nil) }
        if l.matches(#"^(?:turn on|enable|switch to|go to|use) dark mode$"#) || l == "dark mode" || l == "dark mode on" { return .system(.darkModeOn, nil) }
        if l.matches(#"^(?:turn off|disable) dark mode$"#) || l.matches(#"^(?:turn on|enable|switch to|go to|use) light mode$"#) || ["light mode", "dark mode off"].contains(l) { return .system(.darkModeOff, nil) }
        if l == "toggle dark mode" { return .system(.toggleDarkMode, nil) }
        if l.matches(#"^(?:take|grab|capture)(?: a| the)? screen ?shot(?: of the screen)?$"#) || l == "screenshot" { return .system(.screenshot, nil) }
        if l.matches(#"^(?:turn |set )?(?:the )?brightness up$"#) || l.matches(#"^(?:increase|raise) (?:the )?brightness$"#) || l == "brighter" { return .system(.brightnessUp, nil) }
        if l.matches(#"^(?:turn |set )?(?:the )?brightness down$"#) || l.matches(#"^(?:decrease|lower|reduce|dim) (?:the )?(?:brightness|screen)$"#) || l == "dimmer" { return .system(.brightnessDown, nil) }
        if l.matches(#"^show(?: me)?(?: the)? desktop$"#) { return .system(.showDesktop, nil) }
        if l.matches(#"^(?:open |show )?mission control$"#) { return .system(.missionControl, nil) }
        return nil
    }

    private func parseSearch(_ l: String, _ o: String) -> Command? {
        let sites: [String: SearchSite] = [
            "youtube": .youtube, "amazon": .amazon, "github": .github, "maps": .maps, "google maps": .maps,
            "wikipedia": .wikipedia, "google images": .images, "images": .images, "google news": .news,
            "news": .news, "google": .google, "the web": .google, "the internet": .google, "web": .google,
        ]
        let siteNames = sites.keys.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let verbs = #"(?:search|look up|lookup|google|find|look for)"#

        if l.matches("^\(verbs)(?: for| up)? (?:this|that|it|the selection|selected text|the selected text|what i selected)$") {
            return .searchSelection(.google)
        }
        if let m = o.firstMatch("^(?i:\(verbs) (\(siteNames)) for) (.+)$") {
            return .webSearch(Self.query(m[2]), sites[m[1].lowercased()] ?? .google)
        }
        if let m = o.firstMatch("^(?i:\(verbs)(?: for| up)?) (.+?) (?i:on|in|using|with) (?i:(\(siteNames)))$") {
            return .webSearch(Self.query(m[1]), sites[m[2].lowercased()] ?? .google)
        }
        if let m = o.firstMatch(#"^(?i:play) (.+) (?i:on youtube)$"#) { return .webSearch(Self.query(m[1]), .youtube) }
        if let m = o.firstMatch(#"^(?i:youtube) (.+)$"#) { return .webSearch(Self.query(m[1]), .youtube) }
        if let m = o.firstMatch(#"^(?i:(?:get |show me |give me )?directions to|navigate to|how do i get to) (.+)$"#) {
            return .webSearch("directions to " + Self.query(m[1]), .maps)
        }
        if let m = o.firstMatch(#"^(?i:show me (?:pictures|photos|images) of) (.+)$"#) { return .webSearch(Self.query(m[1]), .images) }
        if let m = o.firstMatch(#"^(?i:google)(?i: for)? (.+)$"#) { return .webSearch(Self.query(m[1]), .google) }
        if let m = o.firstMatch(#"^(?i:(?:search|look up|lookup)(?: for| up)?) (.+)$"#) { return .searchHere(Self.query(m[1])) }
        return nil
    }

    static func query(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            .replacingOccurrences(of: #"(?<=\w)[.!?]\s+"#, with: " ", options: .regularExpression)
    }

    private func parseKeys(_ l: String) -> Command? {
        let shortcuts: [String: KeyCombo] = [
            "copy": KeyCombo(key: "c", command: true), "copy that": KeyCombo(key: "c", command: true),
            "copy this": KeyCombo(key: "c", command: true), "copy it": KeyCombo(key: "c", command: true),
            "paste": KeyCombo(key: "v", command: true), "paste it": KeyCombo(key: "v", command: true),
            "paste that": KeyCombo(key: "v", command: true), "cut": KeyCombo(key: "x", command: true),
            "cut that": KeyCombo(key: "x", command: true), "undo": KeyCombo(key: "z", command: true),
            "undo that": KeyCombo(key: "z", command: true), "redo": KeyCombo(key: "z", command: true, shift: true),
            "select all": KeyCombo(key: "a", command: true), "select everything": KeyCombo(key: "a", command: true),
            "save": KeyCombo(key: "s", command: true), "save it": KeyCombo(key: "s", command: true),
            "save this": KeyCombo(key: "s", command: true), "save the file": KeyCombo(key: "s", command: true),
            "zoom in": KeyCombo(key: "=", command: true), "zoom out": KeyCombo(key: "-", command: true),
            "find on page": KeyCombo(key: "f", command: true), "enter": KeyCombo(key: "return"),
            "return": KeyCombo(key: "return"), "escape": KeyCombo(key: "escape"), "submit": KeyCombo(key: "return"),
            "focus the address bar": KeyCombo(key: "l", command: true),
        ]
        if let combo = shortcuts[l] { return .pressKeys(combo) }
        if let m = l.firstMatch(#"^(?:press|hit|tap|push)(?: the)? (.+?)(?: key| keys| button)?$"#), let combo = KeyCombo(spoken: m[1]) {
            return .pressKeys(combo)
        }
        return nil
    }

    private func parseWindow(_ l: String) -> Command? {
        if l.matches(#"^minimi[sz]e(?: this| the| that)?(?: window| app)?$"#) { return .window(.minimize) }
        if l.matches(#"^(?:make (?:it|this|the window) |go |enter |toggle )?full ?screen(?: mode)?$"#) { return .window(.fullscreen) }
        if l.matches(#"^close (?:it|this|that|this one|that one|the current one)$"#) { return .closeCurrent }
        if l.matches(#"^close (?:this|the|that|current)(?: window)?$"#) || l == "close window" { return .window(.close) }
        if l.matches(#"^hide (?:this|the|that|current)(?: window| app)?$"#) { return .window(.hide) }
        if l.matches(#"^(?:maximi[sz]e|zoom)(?: this| the)?(?: window)?$"#) { return .window(.zoom) }
        return nil
    }

    private func parseQuit(_ l: String) -> Command? {
        guard let m = l.firstMatch(#"^(?:quit|close|exit|kill|force quit|shut down)(?: the| my)? (.+?)(?: app| application)?$"#) else { return nil }
        guard let name = resolveApp(m[1]) else { return nil }
        return .quitApp(name)
    }

    static let sites: [String: String] = [
        "youtube": "https://www.youtube.com", "gmail": "https://mail.google.com", "google": "https://www.google.com",
        "google docs": "https://docs.google.com", "google drive": "https://drive.google.com",
        "google sheets": "https://sheets.google.com", "google calendar": "https://calendar.google.com",
        "google maps": "https://maps.google.com", "github": "https://github.com", "twitter": "https://x.com",
        "x": "https://x.com", "linkedin": "https://www.linkedin.com", "facebook": "https://www.facebook.com",
        "instagram": "https://www.instagram.com", "reddit": "https://www.reddit.com", "netflix": "https://www.netflix.com",
        "amazon": "https://www.amazon.com", "chatgpt": "https://chatgpt.com", "claude": "https://claude.ai",
        "wikipedia": "https://www.wikipedia.org", "stack overflow": "https://stackoverflow.com",
        "hacker news": "https://news.ycombinator.com", "whatsapp web": "https://web.whatsapp.com",
        "outlook web": "https://outlook.live.com", "notion": "https://www.notion.so", "figma": "https://www.figma.com",
        "perplexity": "https://www.perplexity.ai", "spotify web": "https://open.spotify.com",
    ]
    static let folders: [String: String] = [
        "downloads": "Downloads", "my downloads": "Downloads", "downloads folder": "Downloads",
        "the downloads folder": "Downloads", "documents": "Documents", "documents folder": "Documents",
        "desktop folder": "Desktop", "my desktop": "Desktop", "home folder": "", "my home folder": "",
        "applications folder": "/Applications", "pictures": "Pictures", "movies": "Movies", "music folder": "Music",
    ]

    private func parseOpen(_ l: String, _ o: String) -> Command? {
        guard let m = l.firstMatch(#"^(?:open|launch|start|run|fire up|bring up|switch to|go to|show|focus|activate|visit|navigate to|take me to)(?: up)? (.+)$"#) else { return nil }
        var target = m[1].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        for prefix in ["the ", "my ", "a "] where target.hasPrefix(prefix) { target.removeFirst(prefix.count) }
        // "open YouTube here / in this tab / instead": where, not what.
        target = target.replacingOccurrences(of: #"\s+(?:right )?(?:here|in here|over here|in this tab|in the same tab|in this window|instead|please)$"#,
                                            with: "", options: .regularExpression)
        for suffix in [" website", " site", " web site", " page", " homepage", " home page"] where target.hasSuffix(suffix) && Self.sites[String(target.dropLast(suffix.count))] != nil {
            target.removeLast(suffix.count)
        }

        if let folder = Self.folders[target] ?? Self.folders[m[1]] {
            let url = folder.hasPrefix("/") ? URL(fileURLWithPath: folder) : Paths.home.appendingPathComponent(folder)
            return .openURL(url)
        }
        if target.matches(#"^[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|org|net|io|ai|dev|app|in|co|uk|me|tv|gg|so|xyz|edu|gov)(/\S*)?$"#) {
            return URL(string: "https://" + target).map(Command.openURL)
        }
        if let app = resolveExactApp(target) { return .openApp(app) }
        if let site = Self.sites[target] { return .openURL(URL(string: site)!) }
        for suffix in [" browser", " app", " application"] where target.hasSuffix(suffix) {
            if let app = resolveApp(String(target.dropLast(suffix.count))) { return .openApp(app) }
        }
        if let app = resolveApp(target) { return .openApp(app) }
        return nil
    }

    private func parseClick(_ l: String, _ o: String) -> Command? {
        // "select the second paragraph" is about text; in no text field it falls back to clicking (see runEditor).
        if l.matches(#"^(?:select|highlight)\b"#) { return .edit(o.trimmingCharacters(in: .whitespaces)) }
        guard let m = o.firstMatch(#"^(?i:click|tap|press|select|hit|choose)(?i: on)?(?i: the)? (.+?)(?i: button| link| tab| option| icon| menu)?$"#) else { return nil }
        let target = m[1].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return target.isEmpty ? nil : .click(target)
    }
}

// MARK: - Helpers

enum NumberWords {
    static let words: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90, "a couple of": 2, "a couple": 2, "a few": 3, "couple of": 2,
    ]

    static func parse(_ text: String) -> Int? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return n }
        if let n = words[t] { return n }
        let parts = t.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        if parts.count == 2, let tens = words[parts[0]], let ones = words[parts[1]], tens >= 20, ones < 10 { return tens + ones }
        return nil
    }
}

public enum Durations {
    /// "10 minutes", "an hour and a half", "half an hour", "90 seconds", "two hours".
    public static func parse(_ text: String) -> TimeInterval? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        if ["half an hour", "a half hour", "half hour"].contains(t) { return 1800 }
        if ["an hour and a half", "one and a half hours", "1 and a half hours", "1.5 hours"].contains(t) { return 5400 }
        if ["a minute", "one minute", "1 minute"].contains(t) { return 60 }
        guard let m = t.firstMatch(#"^(.+?) ?(seconds?|secs?|minutes?|mins?|hours?|hrs?)(?: and (.+?) ?(seconds?|minutes?|mins?))?$"#) else { return nil }
        guard let n = Double(m[1]) ?? NumberWords.parse(m[1]).map(Double.init) else { return nil }
        var total = n * unit(m[2])
        if !m[3].isEmpty, let extra = Double(m[3]) ?? NumberWords.parse(m[3]).map(Double.init) { total += extra * unit(m[4]) }
        return total > 0 ? total : nil
    }

    private static func unit(_ word: String) -> Double {
        if word.hasPrefix("h") { return 3600 }
        if word.hasPrefix("m") { return 60 }
        return 1
    }

    /// "5 pm", "5:30 p.m.", "17:45", "noon" → hour/minute components.
    public static func parseClock(_ text: String) -> DateComponents? {
        let t = text.lowercased().replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
        if t == "noon" || t == "midday" { return DateComponents(hour: 12, minute: 0) }
        if t == "midnight" { return DateComponents(hour: 0, minute: 0) }
        guard let m = t.firstMatch(#"^(\d{1,2})(?::(\d{2}))? ?(am|pm|in the morning|in the evening|in the afternoon|tonight)?$"#),
              var hour = Int(m[1]) else { return nil }
        let minute = Int(m[2]) ?? 0
        let suffix = m[3]
        if ["pm", "in the evening", "in the afternoon", "tonight"].contains(suffix), hour < 12 { hour += 12 }
        if suffix == "am", hour == 12 { hour = 0 }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return DateComponents(hour: hour, minute: minute)
    }
}

extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Capture groups of the first match; missing groups are empty strings.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
