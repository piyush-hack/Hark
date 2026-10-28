import Foundation

/// Turns dictated speech into the text a person meant, the way macOS dictation does, with no model and no delay:
/// spoken punctuation and breaks become symbols, "capital"/"all caps" set the case, spelled-out letters become a word,
/// fillers go. Anything it doesn't know stays as said; the writing pass tidies the rest later.
public enum Dictation {
    /// Symbols said by name. Longest phrases first, so "question mark" wins over "question".
    static let symbols: [(spoken: String, text: String)] = [
        ("new paragraph", "\n\n"), ("next paragraph", "\n\n"), ("paragraph break", "\n\n"), ("new para", "\n\n"),
        ("next para", "\n\n"), ("blank line", "\n\n"), ("dew paragraph", "\n\n"),
        ("new line", "\n"), ("next line", "\n"), ("line break", "\n"), ("newline", "\n"),
        ("new lane", "\n"), ("next lane", "\n"), ("dew line", "\n"),
        ("full stop", "."), ("full stock", "."), ("question mark", "?"), ("question bark", "?"),
        ("exclamation mark", "!"), ("exclamation point", "!"),
        ("open bracket", "("), ("opening bracket", "("), ("open paren", "("), ("open parenthesis", "("), ("open parentheses", "("),
        ("close bracket", ")"), ("closing bracket", ")"), ("close paren", ")"), ("close parenthesis", ")"), ("close parentheses", ")"),
        ("end bracket", ")"), ("bracket close", ")"), ("open square bracket", "["), ("close square bracket", "]"),
        ("open curly bracket", "{"), ("close curly bracket", "}"), ("open brace", "{"), ("close brace", "}"),
        ("open quote", "\u{201C}"), ("open quotes", "\u{201C}"), ("opening quote", "\u{201C}"), ("begin quote", "\u{201C}"),
        ("close quote", "\u{201D}"), ("close quotes", "\u{201D}"), ("closing quote", "\u{201D}"), ("end quote", "\u{201D}"),
        ("open single quote", "\u{2018}"), ("close single quote", "\u{2019}"),
        ("dot dot dot", "\u{2026}"), ("ellipsis", "\u{2026}"), ("at sign", "@"), ("at the rate", "@"), ("at symbol", "@"),
        ("hash tag", "#"), ("hashtag", "#"), ("hash sign", "#"), ("pound sign", "#"), ("percent sign", "%"),
        ("dollar sign", "$"), ("rupee sign", "\u{20B9}"), ("rupee symbol", "\u{20B9}"), ("ampersand", "&"), ("asterisk", "*"),
        ("underscore", "_"), ("forward slash", "/"), ("back slash", "\\"), ("backslash", "\\"), ("slash", "/"),
        ("semi colon", ";"), ("semicolon", ";"), ("colon", ":"), ("comma", ","), ("period", "."), ("apostrophe", "'"),
        ("hyphen", "-"), ("dash", " - "), ("em dash", "\u{2014}"), ("bracket", "("),
    ]

    /// Symbols that are too often ordinary words to convert when an article or "word" comes first: "a comma", "the period".
    static let wordLike: Set<String> = ["comma", "period", "colon", "semicolon", "semi colon", "dash", "hyphen", "slash", "bracket",
                                        "apostrophe", "asterisk", "underscore", "ellipsis", "hashtag", "hash tag"]

    static let fillers: Set<String> = ["uh", "uhh", "um", "umm", "uhm", "erm", "hmm", "hm", "mm", "mhm", "ah", "er"]

    /// Short tokens that are words, never the start of a spelled-out run.
    static let shortWords: Set<String> = ["a", "i", "an", "am", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it",
                                          "me", "my", "no", "of", "ok", "on", "or", "so", "to", "up", "us", "we", "oh", "ya", "yo"]

    /// Renders spoken text. `after` is the character before the caret, so the first word gets a capital at the start of
    /// a sentence and no capital mid-sentence.
    public static func render(_ spoken: String, after previous: Character? = nil) -> String {
        var tokens = tokenize(spoken)
        tokens = dropFillers(tokens)
        tokens = joinSpelled(tokens)
        tokens = applyCase(tokens)
        let text = assemble(tokens)
        return capitalizeStart(text, after: previous)
    }

    /// True when the whole phrase is punctuation and breaks ("new line", "comma", "full stop, new paragraph").
    public static func isOnlySymbols(_ spoken: String) -> Bool {
        let tokens = dropFillers(tokenize(spoken)).filter { if case .word(let w) = $0 { return !["and", "then", "a"].contains(w.lowercased()) }; return true }
        return !tokens.isEmpty && tokens.allSatisfy { if case .symbol = $0 { return true }; return false }
    }

    // MARK: Tokens

    enum Token: Equatable {
        case word(String)
        case symbol(String)
        case capitalNext, capsNext, lowerNext, capsOn, capsOff
    }

    static func tokenize(_ spoken: String) -> [Token] {
        // Keep words with their trailing punctuation from the speech model ("hello," "world."): it is part of the text.
        let raw = spoken.replacingOccurrences(of: "\n", with: " new line ").split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var tokens: [Token] = []
        var i = 0
        while i < raw.count {
            let lower = { (n: Int) in raw[i..<min(raw.count, i + n)].map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }.joined(separator: " ") }
            // Case instructions.
            let two = lower(2), one = lower(1)
            if one == "capital" || one == "cap", i + 1 < raw.count {
                // "capital p paris": the letter names the word's initial. "capital letter a" / "capital a": that letter.
                // "working capital is…" is the noun.
                let skip = raw[i + 1].lowercased().trimmingCharacters(in: .punctuationCharacters) == "letter" ? 1 : 0
                let next = i + 1 + skip < raw.count ? raw[i + 1 + skip].trimmingCharacters(in: .punctuationCharacters) : ""
                if next.count == 1, next.first!.isLetter {
                    if i + 2 + skip < raw.count, raw[i + 2 + skip].lowercased().hasPrefix(next.lowercased()) { tokens.append(.capitalNext); i += 2 + skip; continue }
                    tokens.append(.capitalNext); i += 1 + skip; continue
                }
                // "capital Riverside": the speech model already wrote the name with a capital — the word "capital" was the instruction.
                if skip == 0, next.count > 1, next.first!.isUppercase, i > 0 || raw.count > 2 { tokens.append(.capitalNext); i += 1; continue }
            }
            if two == "all caps" || two == "all capitals" || two == "in caps" { tokens.append(i + 2 < raw.count ? .capsNext : .capsOn); i += 2; continue }
            if two == "caps on" { tokens.append(.capsOn); i += 2; continue }
            if two == "caps off" { tokens.append(.capsOff); i += 2; continue }
            if two == "lower case" || one == "lowercase", i + (two == "lower case" ? 2 : 1) < raw.count {
                tokens.append(.lowerNext); i += two == "lower case" ? 2 : 1; continue
            }
            // Spoken symbols, longest first; "a comma" / "the word comma" stay words.
            var matched = false
            for (spoken, text) in symbols {
                let n = spoken.split(separator: " ").count
                guard i + n <= raw.count, lower(n) == spoken else { continue }
                let before = i > 0 ? raw[i - 1].lowercased().trimmingCharacters(in: .punctuationCharacters) : ""
                // "a comma", "the next line of the poem": the words themselves, not the symbol.
                let after = i + n < raw.count ? raw[i + n].lowercased().trimmingCharacters(in: .punctuationCharacters) : ""
                let determiner = ["a", "an", "the", "this", "that", "each", "every", "word", "any", "no", "another", "my", "your", "our", "his", "her", "their", "its", "first", "last"].contains(before)
                // "period" and a bare "bracket" are usually the words: "the notice period is", "the new tax bracket".
                if spoken == "period", !after.isEmpty, !["new", "next"].contains(after) { break }
                if spoken == "bracket", !before.isEmpty, !["is", "was", "are", "and", "then", "or", "with", "in"].contains(before) { break }
                if (wordLike.contains(spoken) || text.hasPrefix("\n")) && determiner { break }
                if text.hasPrefix("\n"), ["of", "for", "in", "on", "from", "about"].contains(after) { break }
                // A sentence-final "." or "," the speech model attached to the symbol word itself is noise.
                tokens.append(.symbol(text))
                i += n
                matched = true
                break
            }
            if matched { continue }
            tokens.append(.word(raw[i]))
            i += 1
        }
        return tokens
    }

    static func dropFillers(_ tokens: [Token]) -> [Token] {
        tokens.filter { if case .word(let w) = $0 { return !fillers.contains(w.lowercased().trimmingCharacters(in: .punctuationCharacters)) }; return true }
    }

    /// "H A R K" → "Hark", "U S A" → "USA", "Bh A N G" → "Bhang". A run needs at least two single letters.
    static func joinSpelled(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var i = 0
        func letter(_ t: Token) -> String? {
            guard case .word(let w) = t else { return nil }
            let core = w.trimmingCharacters(in: .punctuationCharacters)
            return core.count == 1 && core.first!.isLetter ? core : nil
        }
        while i < tokens.count {
            // "H-A-R-K": the speech model's way of writing spelled letters.
            if case .word(let w) = tokens[i], w.range(of: #"^[A-Za-z](?:-[A-Za-z]){2,}[.,!?]?$"#, options: .regularExpression) != nil {
                let letters = w.filter(\.isLetter)
                let punctuation = w.last.map { ".,!?".contains($0) ? String($0) : "" } ?? ""
                out.append(.word(letters.prefix(1).uppercased() + letters.dropFirst().lowercased() + punctuation))
                dedupeSpelled(&out)
                i += 1
                continue
            }
            var j = i
            var letters: [String] = []
            while j < tokens.count, let l = letter(tokens[j]) { letters.append(l); j += 1 }
            // "i" and "a" alone are words: a run needs a letter that isn't, or three letters.
            let real = letters.count >= 3 || letters.contains { !["a", "i"].contains($0.lowercased()) }
            if letters.count >= 2, real {
                var head = ""
                // "Bh A N G": a short non-word token right before the run belongs to it.
                if let last = out.last, case .word(let w) = last {
                    let core = w.trimmingCharacters(in: .punctuationCharacters)
                    if core.count <= 2, core.allSatisfy(\.isLetter), !shortWords.contains(core.lowercased()), w == core { head = core; out.removeLast() }
                }
                let spelled = head + letters.joined()
                let word = spelled.count <= 3 && head.isEmpty ? spelled.uppercased() : spelled.prefix(1).uppercased() + spelled.dropFirst().lowercased()
                // Trailing punctuation of the last letter ("K.") stays on the word.
                if case .word(let lastWord) = tokens[j - 1], let p = lastWord.last, ".,!?;:".contains(p) { out.append(.word(word + String(p))) } else { out.append(.word(word)) }
                dedupeSpelled(&out)
                i = j
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    /// "Sean, S E A N" → "Sean": a word said and then spelled is written once, as spelled.
    static func dedupeSpelled(_ out: inout [Token]) {
        guard out.count >= 2, case .word(let spelled) = out[out.count - 1], case .word(let said) = out[out.count - 2] else { return }
        let a = said.trimmingCharacters(in: .punctuationCharacters), b = spelled.trimmingCharacters(in: .punctuationCharacters)
        guard a.count >= 2, b.count >= 2, a.first?.lowercased() == b.first?.lowercased() || Vocabulary.soundKey(a) == Vocabulary.soundKey(b),
              AppCatalog.distance(a.lowercased(), b.lowercased()) <= max(1, b.count / 3) else { return }
        // Keep the spelling, with whatever punctuation followed the spelled run.
        var tail = String(spelled.reversed().prefix { ".,!?;:".contains($0) }.reversed())
        if tail == ",", said.hasSuffix(",") { tail = "" }
        out.removeLast(2)
        out.append(.word(b + tail))
    }

    static func applyCase(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var capsOn = false
        var next: Token?
        for token in tokens {
            switch token {
            case .capitalNext, .capsNext, .lowerNext: next = token
            case .capsOn: capsOn = true
            case .capsOff: capsOn = false
            case .symbol: out.append(token)
            case .word(let w):
                var word = w
                if capsOn || next == .capsNext { word = w.uppercased() }
                else if next == .capitalNext { word = w.prefix(1).uppercased() + w.dropFirst() }
                else if next == .lowerNext { word = w.lowercased() }
                next = nil
                out.append(.word(word))
            }
        }
        return out
    }

    static func assemble(_ tokens: [Token]) -> String {
        var text = ""
        var capNext = false  // after a spoken full stop, question mark or line break
        var joinNext = false  // after "underscore", "hyphen", "slash", "at sign": the next word joins on
        for token in tokens {
            switch token {
            case .word(let w):
                if let last = text.last, !last.isWhitespace, !"(\u{201C}\u{2018}[{".contains(last), !joinNext { text += " " }
                text += capNext ? w.prefix(1).uppercased() + w.dropFirst() : w
                capNext = false
                joinNext = false
            case .symbol(let s):
                if s.hasPrefix("\n") || ".?!".contains(s) { capNext = true }
                if s.hasPrefix("\n") {
                    while let last = text.last, last == " " { text.removeLast() }
                    text += s
                } else if ",.?!;:)\u{201D}\u{2019}]}%".contains(s) || s == "\u{2026}" || s == "'" {
                    while let last = text.last, last == " " { text.removeLast() }
                    // The speech model's own comma before a spoken "comma" doubles up.
                    if let last = text.last, ",.?!;:".contains(last), ",.?!;:".contains(s) { text.removeLast() }
                    text += s
                } else if s == " - " {
                    while let last = text.last, last == " " { text.removeLast() }
                    text += " - "
                } else if s == "-" || s == "_" || s == "/" || s == "\\" || s == "@" {
                    while let last = text.last, last == " " { text.removeLast() }
                    text += s
                    joinNext = true
                } else if s == "\u{2013}" || s == "\u{2014}" {
                    if let last = text.last, !last.isWhitespace { text += " " }
                    text += s + " "
                } else {
                    if let last = text.last, !last.isWhitespace, !"(\u{201C}\u{2018}".contains(last) { text += " " }
                    text += s
                }
            default: break
            }
        }
        // No space right after an opening symbol, none before a closing one; single spaces otherwise.
        // Curly quotes only mark which side a quote is on; straight ones work in every app, code editors included.
        return text.replacingOccurrences(of: #"([(\u{201C}\u{2018}\[{@/_\\]) +"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A capital at the start of a sentence — the field's start, after a line break, or after . ! ? — and nowhere else.
    static func capitalizeStart(_ text: String, after previous: Character?) -> String {
        let sentenceStart = previous == nil || previous == "\n" || ".!?".contains(previous!)
        guard sentenceStart, let index = text.firstIndex(where: { !"(\u{201C}\u{2018}[{\" '".contains($0) }),
              text[index].isLetter, text[index].isLowercase else { return text }
        return String(text[..<index]) + text[index].uppercased() + text[text.index(after: index)...]
    }
}
