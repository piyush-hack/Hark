import AppKit
import ApplicationServices

/// The words on screen around what you're writing. Speech recognition doesn't know the names and terms in front of you
/// ("WABA", "FluidAudio", a colleague's name, a "Workflow node" label) and writes something that sounds like them; the
/// writing pass puts them right once it sees them. Read with on-device OCR, which reads every app (web views and
/// terminals too). A read starts the moment you start speaking in a text field, so it's ready by the time your words
/// are, and is kept for the window a while: what's around a field rarely changes while you write in it.
@MainActor
public final class ScreenWords {
    struct Reading {
        let window: AXUIElement
        let title: String
        let lines: [OCRLine]
        let field: CGRect?
        let frame: CGRect
        let at: Date
        let terms: [String]
    }

    private var latest: Reading?
    private var reading: Task<Void, Never>?
    private var known: [String: Bool] = [:]
    /// A window is read again after this long, or when its title changes (another tab, file or chat).
    static let freshFor: TimeInterval = 20
    /// Older than this, a reading isn't used: it's another screen by then.
    static let usableFor: TimeInterval = 120

    public init() {}

    /// Names and terms from the latest reading, for recognizers that take hints.
    public var hints: [String] {
        guard let latest, Date().timeIntervalSince(latest.at) < Self.usableFor else { return [] }
        return Array(latest.terms.prefix(30))
    }

    /// Starts reading the front window, unless it was read just now. Call when speech starts in a text field.
    public func refresh() {
        guard reading == nil, let front = frontWindow() else { return }
        if let latest, CFEqual(latest.window, front.window), latest.title == front.title,
           Date().timeIntervalSince(latest.at) < Self.freshFor { return }
        let field = AX.value(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute).flatMap { AX.frame($0 as! AXUIElement) } // swiftlint:disable:this force_cast
        let started = Date()
        reading = Task { [weak self] in
            let lines = (try? await ScreenText.recognize(app: front.pid, area: front.frame, languageCorrection: false)) ?? []
            guard let self else { return }
            let terms = Self.terms(in: lines.map(\.text), isWord: self.isWord)
            self.latest = Reading(window: front.window, title: front.title, lines: lines, field: field, frame: front.frame, at: Date(), terms: terms)
            self.reading = nil
            Log.info(String(format: "Read the screen around the field in %.2fs: %d lines, %d terms", Date().timeIntervalSince(started), lines.count, terms.count))
        }
    }

    /// The screen for the writing model: "[On screen]" (its names and terms, and the lines nearest the field) and
    /// "[Sounds like]" (words in `newest` that sound almost like words there). `typed` is everything Hark typed in
    /// this session: lines showing it are left out, as they may hold the very mishearing to fix. Waits up to `wait`
    /// for a read in progress; nil when there's no reading of this window.
    public func context(newest: String, typed: String, wait: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(wait)
        while reading != nil, Date() < deadline { try? await Task.sleep(nanoseconds: 40_000_000) }
        if reading != nil { Log.info("The screen isn't read yet: going without it") }
        guard let latest, Date().timeIntervalSince(latest.at) < Self.usableFor,
              let front = frontWindow(), CFEqual(latest.window, front.window) else { return nil }
        let typedWords = Self.words(typed)
        let grams = Self.trigrams(typedWords)
        let kept = latest.lines.filter { !Self.shows(typedWords, grams: grams, in: $0.text) }
        let terms = kept.count == latest.lines.count ? latest.terms : Self.terms(in: kept.map(\.text), isWord: isWord)
        let near = Self.nearest(kept, to: latest.field, in: latest.frame).map(Self.scrub)
        let labels = kept.map(\.text).filter { Self.words($0).count <= 6 } + near
        let pairs = Self.soundAlikes(in: newest, terms: terms, labels: labels)
        guard !terms.isEmpty || !near.isEmpty else { return nil }
        var lines = ["[On screen] terms: " + terms.joined(separator: ", ")]
        if !near.isEmpty { lines.append(near.joined(separator: " · ")) }
        if !pairs.isEmpty { lines.append("[Sounds like] " + pairs.map { "“\($0.heard)” ≈ “\($0.screen)”" }.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    private func frontWindow() -> (window: AXUIElement, title: String, pid: pid_t, frame: CGRect)? {
        guard ScreenText.hasPermission, let app = AX.frontmostApp(), app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = AX.focusedWindow(app), let frame = AX.frame(window), frame.width > 120, frame.height > 80 else { return nil }
        return (window, AX.string(window, kAXTitleAttribute) ?? "", app.processIdentifier, frame)
    }

    /// In the dictionary (any case), so not a name or term speech recognition would miss.
    private func isWord(_ word: String) -> Bool {
        let key = word.lowercased()
        if let answer = known[key] { return answer }
        let miss = NSSpellChecker.shared.checkSpelling(of: key, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        if known.count > 5_000 { known.removeAll() }
        known[key] = miss.location == NSNotFound
        return miss.location == NSNotFound
    }

    // MARK: Reading the text (pure, for tests)

    nonisolated static let stopwords: Set<String> = ["a", "an", "the", "to", "of", "in", "on", "at", "for", "and", "or", "but", "is", "are", "was",
                                         "were", "be", "it", "its", "this", "that", "with", "as", "by", "from", "i", "you", "we", "they",
                                         "he", "she", "my", "your", "our", "their", "me", "us", "them", "so", "if", "then", "than", "not",
                                         "no", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should", "just",
                                         "up", "out", "about", "into", "over", "there", "here", "what", "which", "who", "when", "all"]

    nonisolated static let edges = CharacterSet(charactersIn: "()[]{}<>,;:\"'“”‘’!?*…|·•.#").union(.whitespaces)

    /// The distinctive words in `lines`, most frequent first: names, identifiers, acronyms, words the dictionary lacks.
    nonisolated public static func terms(in lines: [String], isWord: (String) -> Bool, limit: Int = 50) -> [String] {
        var seen: [String: (term: String, count: Int, first: Int)] = [:]
        var order = 0
        for line in lines {
            for raw in line.split(whereSeparator: \.isWhitespace) {
                let token = String(raw).trimmingCharacters(in: edges)
                guard isTerm(token, isWord: isWord) else { continue }
                seen[token.lowercased(), default: (token, 0, order)].count += 1
                order += 1
            }
        }
        return seen.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }.prefix(limit).map(\.term)
    }

    nonisolated static func isTerm(_ token: String, isWord: (String) -> Bool) -> Bool {
        let letters = token.filter(\.isLetter).count
        guard letters >= 2, token.count <= 32, !token.contains("@"), !token.contains("://"), !looksSecret(token) else { return false }
        if token.has(#"\p{Ll}\p{Lu}"#) { return true }                                      // FluidAudio, iPhone, useState
        if token.has(#"^[A-Z][A-Z0-9&]{1,7}s?$"#) { return letters < 4 || !isWord(token) }   // WABA, PDF, S3 — not SAVE
        if token.contains(where: \.isNumber) { return token.count <= 16 }                       // gpt-4o, H264
        if token.has(#"\w[_./-]\w"#) {                                                     // html_to_pdf, bejoyous.ai — not built-in
            return letters >= 4 && !token.split(separator: "-").allSatisfy { isWord(String($0)) }
        }
        guard letters >= 3, token.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return false }
        return !isWord(token)                                                                   // Piyush, Joyz
    }

    /// API keys, tokens and hashes are never sent anywhere.
    nonisolated static func looksSecret(_ token: String) -> Bool {
        token.has(#"^[0-9a-fA-F]{16,}$"#) || token.has(#"^(?:sk|pk|rk)-|^gh[pousr]_|^xox[bpas]-|^AKIA"#)
            || (token.count >= 20 && token.has(#"^[A-Za-z0-9+/=_-]+$"#) && token.contains(where: \.isNumber))
    }

    /// A line with secrets and addresses taken out.
    nonisolated static func scrub(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: false).map { word in
            let core = String(word).trimmingCharacters(in: edges)
            return looksSecret(core) || core.contains("@") ? "…" : String(word)
        }.joined(separator: " ")
    }

    /// The words as written, punctuation around them taken off.
    nonisolated static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: edges) }.filter { !$0.isEmpty }
    }

    /// Lowercased words without punctuation, for comparing text.
    nonisolated static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    nonisolated static func trigrams(_ words: [String]) -> Set<String> {
        guard words.count >= 3 else { return [] }
        return Set((0...(words.count - 3)).map { words[$0..<$0 + 3].joined(separator: " ") })
    }

    /// The line shows what Hark typed (the field itself, read back), not something else on screen.
    nonisolated static func shows(_ typed: [String], grams: Set<String>, in line: String) -> Bool {
        let own = words(line)
        guard !own.isEmpty, !typed.isEmpty else { return false }
        if own.count >= 3 { return !trigrams(own).isDisjoint(with: grams) }
        return (" " + typed.joined(separator: " ") + " ").contains(" " + own.joined(separator: " ") + " ")
    }

    /// The lines closest to the field, in reading order, none inside it (that's the field's own text). None when the
    /// field fills the window (a document: its text is the context already).
    nonisolated static func nearest(_ lines: [OCRLine], to field: CGRect?, in window: CGRect, budget: Int = 700) -> [String] {
        guard let field, field.width * field.height < window.width * window.height * 0.5 else { return [] }
        let inside = field.insetBy(dx: -2, dy: -2)
        func distance(_ r: CGRect) -> CGFloat {
            let dy = r.maxY < field.minY ? field.minY - r.maxY : (r.minY > field.maxY ? r.minY - field.maxY : 0)
            let dx = r.maxX < field.minX ? field.minX - r.maxX : (r.minX > field.maxX ? r.minX - field.maxX : 0)
            return dy + dx / 2
        }
        var picked: [OCRLine] = []
        var used = 0
        for line in lines.filter({ !inside.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }).sorted(by: { distance($0.frame) < distance($1.frame) }) {
            guard used + line.text.count <= budget else { continue }
            picked.append(line)
            used += line.text.count + 3
        }
        return picked.sorted { abs($0.frame.minY - $1.frame.minY) > 4 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }.map(\.text)
    }

    /// Words in `newest` that sound almost like a term on screen ("pew ish" ≈ "Piyush", "fluid audio" ≈ "FluidAudio"),
    /// or like a word in a short label next to the same word ("workflow mode" ≈ "Workflow node"). Only candidates:
    /// the writing model decides, from what makes sense.
    nonisolated static func soundAlikes(in newest: String, terms: [String], labels: [String], limit: Int = 6) -> [(heard: String, screen: String)] {
        let said = tokens(newest)
        var found: [(heard: String, screen: String, distance: Int)] = []
        func add(_ heard: String, _ screen: String, _ distance: Int) {
            guard !found.contains(where: { $0.heard.lowercased() == heard.lowercased() || $0.screen == screen && $0.heard == heard }) else { return }
            found.append((heard, screen, distance))
        }
        /// `anchored`: the word next to it was heard right, so even a short word one sound off counts ("mode" ≈ "node").
        func near(_ a: String, _ b: String, anchored: Bool = false) -> Int? {
            let la = Vocabulary.letters(a), lb = Vocabulary.letters(b)
            guard la.count >= 3, lb.count >= 3 else { return nil }
            let ka = Vocabulary.soundKey(a), kb = Vocabulary.soundKey(b)
            let d = AppCatalog.distance(ka, kb)
            let short = min(ka.count, kb.count)
            guard d == 0 && short >= 2 || d == 1 && (short >= 3 || anchored && short >= 2) else { return nil }
            let spelling = 1 - Double(AppCatalog.distance(la, lb)) / Double(max(la.count, lb.count))
            return spelling >= (anchored ? 0.5 : 0.4) ? d : nil
        }
        // A term on screen, said as one to three words.
        for n in 1...3 where said.count >= n {
            for i in 0...(said.count - n) {
                let window = Array(said[i..<i + n])
                let lower = window.map { $0.lowercased() }
                if lower.allSatisfy(stopwords.contains) || n > 1 && (stopwords.contains(lower[0]) || stopwords.contains(lower[n - 1])) { continue }
                let heard = window.joined(separator: " ")
                for term in terms {
                    let same = Vocabulary.letters(heard) == Vocabulary.letters(term)
                    if same && (n == 1 || heard.lowercased() == term.lowercased()) { continue }  // "node" ≈ "Node" isn't news
                    if let d = same ? 0 : near(heard, term) { add(heard, term, d) }
                }
            }
        }
        // A two-word label with one word heard right and the other one sound off.
        var bigrams = Set<String>()
        for label in labels {
            let w = tokens(label)
            for j in 0..<max(0, w.count - 1) { bigrams.insert(w[j] + " " + w[j + 1]) }
        }
        let pairs = bigrams.sorted()
        for i in 0..<max(0, said.count - 1) {
            let (a, b) = (said[i], said[i + 1])
            for pair in pairs {
                let parts = pair.split(separator: " ").map(String.init)
                let (c, d) = (parts[0], parts[1])
                let x: String, y: String
                if a.lowercased() == c.lowercased(), b.lowercased() != d.lowercased() { (x, y) = (b, d) }
                else if b.lowercased() == d.lowercased(), a.lowercased() != c.lowercased() { (x, y) = (a, c) }
                else { continue }
                guard !stopwords.contains(x.lowercased()), !stopwords.contains(y.lowercased()), let distance = near(x, y, anchored: true) else { continue }
                add(a + " " + b, pair, distance)
            }
        }
        return found.sorted { $0.distance < $1.distance }.prefix(limit).map { ($0.heard, $0.screen) }
    }
}

private extension String {
    /// Case matters here: "WABA" is an acronym, "waba" isn't.
    func has(_ pattern: String) -> Bool { range(of: pattern, options: .regularExpression) != nil }
}
