import Foundation

/// Turns how people *say* things into how they're *written*: "a at the rate joyz dot ai" → a@joyz.ai.
/// Speech models garble addresses (and Indian English says "at the rate" for @), so this runs before parsing.
public enum SpokenText {
    static let commonDomains = ["gmail.com", "yahoo.com", "outlook.com", "hotmail.com", "icloud.com", "proton.me", "live.com", "rediffmail.com"]
    static let dotWords = "dot|dirty|dart|dirt|dut|daat"
    static let tlds = "com|ai|a i|in|io|org|net|co|dev|app|me|us|uk|edu|gov|info|xyz|so|tv|ie|i"

    /// Sites people say a lot; misheard addresses snap to these (plus the user's own words).
    public static let knownSites = [
        "claude.ai", "gemini.google.com", "chatgpt.com", "perplexity.ai", "google.com", "youtube.com", "mail.google.com",
        "gmail.com", "github.com", "linkedin.com", "x.com", "reddit.com", "amazon.in", "amazon.com", "flipkart.com",
        "netflix.com", "notion.so", "figma.com", "slack.com", "stackoverflow.com", "wikipedia.org", "web.whatsapp.com",
        "instagram.com", "facebook.com", "docs.google.com", "drive.google.com", "calendar.google.com", "outlook.com",
    ]

    public static func normalize(_ text: String, known: [String] = []) -> String {
        fixDomains(normalizeEmails(unglue(text), known: known), known: known)
    }

    /// The speech model sometimes glues a verb to the next word: "OpenGermany.google.com", "Opencloud.ie".
    public static func unglue(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"\b(Open|Close|Search|Type|Click|Launch|Quit|Visit)(?=[A-Z])"#, with: "$1 ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\b(open|visit|close|search)(?=[a-z0-9-]{2,}\.(?:com|ai|org|net|io|in|co|dev|app|me|ie|i)\b)"#,
                                   with: "$1 ", options: .regularExpression)
        return s
    }

    /// "cloud.ai" → claude.ai, "Germany.google.com" → gemini.google.com, "gemini dot google dot com" → gemini.google.com.
    public static func fixDomains(_ text: String, known: [String]) -> String {
        // Spoken dots: "gemini dot google dot com" → gemini.google.com (only when it ends in a real TLD).
        var s = joinSpokenDots(text)
        let candidates = (known.filter { !$0.contains("@") && $0.contains(".") } + knownSites).map { $0.lowercased() }
        guard let regex = try? NSRegularExpression(pattern: "(?i)(?<![@\\w.])([a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.(?:com|ai|org|net|io|in|co|dev|app|me|so|tv|ie|i))\\b") else { return s }
        let ns = s as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let heard = ns.substring(with: match.range(at: 1))
            result += snapDomain(heard, candidates: candidates) ?? heard
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    static func joinSpokenDots(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let tldSet = Set(tlds.split(separator: "|").map(String.init))
        func isLabel(_ w: String) -> Bool { !w.isEmpty && w.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." } }
        var out: [String] = []
        var i = 0
        while i < words.count {
            var parts = [words[i]]
            var j = i
            while j + 2 < words.count, words[j + 1].lowercased() == "dot",
                  isLabel(words[j + 2].trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-.")))) {
                parts.append(words[j + 2])
                j += 2
            }
            let last = parts.last?.lowercased().trimmingCharacters(in: .punctuationCharacters) ?? ""
            if parts.count >= 2, isLabel(parts[0]), tldSet.contains(last) {
                out.append(parts.joined(separator: ".").lowercased())
                i = j + 1
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    static func snapDomain(_ heard: String, candidates: [String]) -> String? {
        let lower = heard.lowercased()
        if candidates.contains(lower) { return lower }
        let labels = lower.split(separator: ".").map(String.init)
        guard let first = labels.first else { return nil }
        var best: (String, Double)?
        for candidate in candidates {
            let parts = candidate.split(separator: ".").map(String.init)
            // Same shape and same ending (".google.com", ".ai"); only the name was misheard.
            // ".ai" is often heard as ".ie" or ".i".
            let sameEnding = Array(parts.dropFirst()) == Array(labels.dropFirst())
                || (parts.count == 2 && labels.count == 2 && parts[1] == "ai" && ["ie", "i", "aye", "eye"].contains(labels[1]))
            guard parts.count == labels.count, sameEnding, let name = parts.first else { continue }
            let keyDistance = AppCatalog.distance(Vocabulary.soundKey(first), Vocabulary.soundKey(name))
            let spelling = 1 - Double(AppCatalog.distance(first, name)) / Double(max(first.count, name.count))
            guard keyDistance <= 1, spelling >= 0.4 else { continue }
            if spelling > (best?.1 ?? 0) { best = (candidate, spelling) }
        }
        return best?.0
    }

    public static func normalizeEmails(_ text: String, known: [String] = []) -> String {
        let at = "(?:\\s*@\\s*|\\s+at\\s+the\\s+(?:rate|red|read|rat|rait|raid|rated|right)(?:\\s+of)?\\s*|\\s+at\\s+(?:sign|symbol)\\s+)"
        let label = "[a-z0-9-]+"
        let sep = "(?:\\s*\\.\\s*|\\s+(?:\(dotWords))\\s+)"
        let pattern = "(?i)\\b([a-z0-9][a-z0-9._-]*)\(at)(\(label)(?:\(sep)\(label))*)(?:\\s+(?:\(dotWords))\\s+(\(tlds))\\b)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let original = ns.substring(with: match.range)
            let local = ns.substring(with: match.range(at: 1)).lowercased()
            var domain = ns.substring(with: match.range(at: 2)).lowercased()
                .replacingOccurrences(of: "\\s*(?:\\.|\\b(?:\(dotWords))\\b)\\s*", with: ".", options: .regularExpression)
            if match.range(at: 3).location != NSNotFound { domain += "." + ns.substring(with: match.range(at: 3)).lowercased() }
            domain = domain.replacingOccurrences(of: #"\.(?:a\s?i|i)$"#, with: ".ai", options: .regularExpression)
            let snapped = snap(local: local, domain: domain, known: known)
            // Only a real-looking address counts: "meet me at the red door" stays a sentence.
            let snappedDomain = snapped.split(separator: "@").last.map(String.init) ?? ""
            let looksReal = snappedDomain.contains(".") && snappedDomain.range(of: "\\.[a-z]{2,}$", options: .regularExpression) != nil
            result += looksReal ? snapped : original
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Prefers addresses and domains the user taught Hark, then common mail providers.
    static func snap(local: String, domain: String, known: [String]) -> String {
        let name = domain.split(separator: ".").first.map(String.init) ?? domain
        let emails = known.filter { $0.contains("@") }.map { $0.lowercased() }
        let domains = known.filter { !$0.contains("@") && $0.contains(".") }.map { $0.lowercased() } + commonDomains
            + emails.compactMap { $0.split(separator: "@").last.map(String.init) }

        func sameDomain(_ candidate: String) -> Bool {
            let candidateName = candidate.split(separator: ".").first.map(String.init) ?? candidate
            if candidate == domain || candidateName == name { return true }
            let keysMatch = Vocabulary.soundKey(candidateName) == Vocabulary.soundKey(name) && Vocabulary.soundKey(name).count >= 2
            let spelling = 1 - Double(AppCatalog.distance(candidateName, name)) / Double(max(candidateName.count, name.count, 1))
            return keysMatch || spelling >= 0.7
        }

        for email in emails {
            let parts = email.split(separator: "@").map(String.init)
            guard parts.count == 2, sameDomain(parts[1]) else { continue }
            let localKey = Vocabulary.soundKey(local), knownKey = Vocabulary.soundKey(parts[0])
            if local == parts[0] || AppCatalog.distance(localKey, knownKey) <= 1 && max(local.count, parts[0].count) <= 3
                || localKey == knownKey {
                return email
            }
        }
        if let match = domains.first(where: sameDomain) { return local + "@" + match }
        return local + "@" + domain
    }
}
