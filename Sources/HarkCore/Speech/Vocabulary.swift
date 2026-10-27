import Foundation

/// Fixes mis-heard names by sound: "groom" → Chrome, "bijoyus.i" → bejoyous.ai, "Kiosh" → Piyush.
/// Speech models know common words well but not your apps, brands, and people.
public enum Vocabulary {
    /// A rough pronunciation key: consonant skeleton with sound-alike letters merged.
    public static func soundKey(_ text: String) -> String {
        var s = text.lowercased().filter { $0.isLetter }
        for (from, to) in [("ph", "f"), ("ch", "k"), ("ck", "k"), ("sh", "s"), ("th", "t"), ("wh", "w"), ("qu", "kw"), ("x", "ks")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        // Soft c sounds like s: "Joice" ~ "Joyz".
        s = s.replacingOccurrences(of: "c(?=[eiy])", with: "s", options: .regularExpression)
        // Soft g sounds like j: "Gemini" ~ "Germany".
        s = s.replacingOccurrences(of: "g(?=[eiy])", with: "j", options: .regularExpression)
        let map: [Character: Character] = ["c": "k", "g": "k", "q": "k", "z": "s", "v": "f", "w": "f", "b": "p", "d": "t"]
        var key = ""
        for (i, ch) in s.enumerated() {
            if "aeiouyh".contains(ch) { if i == 0 { key.append("a") }; continue }
            let mapped = map[ch] ?? ch
            if key.last != mapped { key.append(mapped) }
        }
        return key
    }

    static func letters(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Replaces 1–3 word spans that sound like a vocabulary term.
    public static func correct(_ text: String, terms: [String]) -> String {
        let candidates = terms.compactMap { term -> (term: String, key: String, plain: String)? in
            let key = soundKey(term)
            return key.count >= 2 ? (term, key, letters(term)) : nil
        }
        guard !candidates.isEmpty else { return text }
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < words.count {
            var replaced = false
            for span in stride(from: 3, through: 1, by: -1) where i + span <= words.count {
                let chunk = words[i..<i + span].joined(separator: " ")
                if chunk.contains("@") { continue }
                let core = chunk.trimmingCharacters(in: .punctuationCharacters)
                let plain = letters(core)
                guard plain.count >= 3 else { continue }
                let key = soundKey(core)
                for c in candidates where c.plain != plain {
                    let keyDistance = AppCatalog.distance(key, c.key)
                    let spelling = 1 - Double(AppCatalog.distance(plain, c.plain)) / Double(max(plain.count, c.plain.count))
                    // Same sound skeleton → accept loose spelling; near skeleton → demand closer spelling.
                    let minimumSpelling: Double
                    if keyDistance == 0 { minimumSpelling = c.key.count >= 3 ? 0.3 : 0.6 }
                    // Short names: allow one swapped sound ("pts" ~ "pjs"), never an extra one ("klts" ≠ "klt").
                    else if keyDistance == 1 && (c.key.count >= 4 || (c.key.count == 3 && key.count == 3)) { minimumSpelling = 0.55 }
                    else { continue }
                    guard spelling >= minimumSpelling, abs(plain.count - c.plain.count) <= max(3, c.plain.count / 2) else { continue }
                    let trailing = chunk.reversed().prefix { ".,!?;:".contains($0) }
                    words.replaceSubrange(i..<i + span, with: [c.term + String(trailing.reversed())])
                    replaced = true
                    break
                }
                if replaced { break }
            }
            i += 1
        }
        return words.joined(separator: " ")
    }
}
