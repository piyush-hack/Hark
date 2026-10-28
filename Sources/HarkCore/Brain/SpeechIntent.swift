import Foundation
import NaturalLanguage

/// What a phrase heard in a text field is for — decided locally, in about a millisecond, before anything is typed:
/// a stop, keys, punctuation, an instruction about the text, a request for Hark, or words to type.
/// Typing a command into a document is the worst outcome, so a phrase that could be a command is never typed blindly:
/// when the words alone can't tell, the writing model decides first (`askFirst`).
public enum SpeechIntent: Equatable {
    /// Stop typing and whatever Hark is doing.
    case stop
    /// Bare keys or shortcuts ("command z", "backspace"), `times` over.
    case keys(KeyCombo, times: Int)
    /// Only punctuation or breaks: insert them.
    case punctuation(String)
    /// Dictation: the rendered text to type now, and a command to run after it ("type hello, then send it").
    case words(String, then: String?)
    /// An instruction about the text (select, delete, bold, scratch that, put it in brackets…): needs exact edit steps.
    case edit
    /// A request for Hark that isn't about this text: an instant command or Claude.
    case request
    /// Could be either: the writing model decides before anything is typed.
    case askFirst
    /// A sentence cut off by a pause ("Even though I"): wait for the rest.
    case hold
    /// A filler or noise.
    case ignore
    /// "start typing", "take dictation": what comes next is dictation, even orders to the reader.
    case startDictation

    public enum FieldKind: String, Sendable { case none, singleLine = "one-line", cell, area = "text" }

    /// For the log.
    public var name: String {
        switch self {
        case .stop: return "stop"
        case .keys(let combo, let times): return "keys \(combo)\(times > 1 ? " ×\(times)" : "")"
        case .punctuation(let text): return "punctuation \(text.debugDescription)"
        case .words(let text, let then): return "type “\(text)”" + (then.map { " then “\($0)”" } ?? "")
        case .edit: return "edit"
        case .request: return "request for Hark"
        case .askFirst: return "ask the writing model first"
        case .hold: return "hold for the rest"
        case .ignore: return "ignore"
        case .startDictation: return "start dictating"
        }
    }

    /// An instruction the writing pass can carry out by rewriting what was just dictated ("put that in brackets",
    /// "I meant sixty", "replace X with Y") — as opposed to formatting, selection or cursor moves, which need edit steps.
    public static func rewritesDictation(_ phrase: String) -> Bool {
        let l = lower(phrase)
        if hasFormattingWord(l) { return false }
        if l.matches(#"^(?:select|highlight|copy|paste|cut|clear|empty|go|move|jump|put the cursor|cursor|caret)\b"#) { return false }
        return true
    }

    /// "scratch that", "delete that", "cancel that": take back the last thing typed.
    public static func takesBackLast(_ phrase: String) -> Bool {
        lower(phrase).replacingOccurrences(of: #"^(?:(?:no|wait|oh|oops|sorry)[, ]+)+"#, with: "", options: .regularExpression)
            .matches(#"^(?:scratch|strike|cancel|forget|undo|delete|remove|erase|drop) (?:that|it|this|the last (?:one|bit|thing|part|phrase)|what i (?:just )?(?:said|typed))$"#)
    }

    public struct Context: Sendable {
        public var kind: FieldKind
        /// Hark typed the previous phrase(s) here and the caret is still after them: a dictation session is open.
        public var dictating: Bool
        /// The text just before the caret (what was dictated), for "replace X with Y" and "yes" after "the answer is".
        public var recentText: String
        /// The last character before the caret, ignoring spaces ("\n" for a fresh line); nil at the start of the field.
        /// Decides whether a phrase starts a sentence.
        public var before: Character??
        /// Hark asked a question a moment ago ("which one?"): a short reply answers it.
        public var harkAsked: Bool
        /// Whether a name resolves to an installed app or a known site ("open Chrome" vs "open the window").
        public var isApp: @Sendable (String) -> Bool

        public init(kind: FieldKind, dictating: Bool, recentText: String = "", before: Character?? = .none, harkAsked: Bool = false,
                    isApp: @escaping @Sendable (String) -> Bool = { _ in false }) {
            self.kind = kind
            self.dictating = dictating
            self.recentText = recentText
            self.before = before
            self.harkAsked = harkAsked
            self.isApp = isApp
        }

        /// What the next words follow: the field's text when it could be read, else what Hark typed.
        var previous: Character? {
            if let known = before { return known }
            return dictating ? recentText.last(where: { $0 != " " }) : nil
        }
    }

    // MARK: Classification

    /// `allowHold: false` once a held fragment has waited long enough: it is then taken as it is.
    public static func classify(_ phrase: String, in ctx: Context, allowHold: Bool = true) -> SpeechIntent {
        let raw = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .ignore }
        let (text, addressed) = stripAddress(raw)
        let l = lower(text)
        guard !l.isEmpty else { return addressed ? .hold : .ignore }

        // 1. Stop, in any wording, before anything else ("cancel that" while dictating takes back the last words instead).
        let unprefixed = l.replacingOccurrences(of: #"^(?:(?:no|wait|oh|oops|sorry|hmm|ugh|damn|damn it|shit|fuck|for fuck's sake|for god's sake|oh my god|what the hell|bloody hell|come on|god)[, ]+)+"#, with: "", options: .regularExpression)
        if ctx.dictating, unprefixed.matches(#"^(?:cancel|forget|scratch|undo|delete|remove) (?:that|it|this)$"#) { return .edit }
        if unprefixed != l, isStop(unprefixed) { return .stop }
        // "Hark, stop, that's not what I said" / "stop, wrong one": the stop comes first.
        if l.matches(#"^(?:stop|wait|hold on|no stop|stop stop), \S"#) { return .stop }
        // "send it", "I think this one's good to send", "full stop and send".
        if isSend(text) { return .request }
        // "don't type, just delete the note" / "don't type that but open YouTube": the part after is the request.
        if let m = unprefixed.firstMatch(#"^(?:don'?t|do not|stop) (?:\S+ )?(?:type|typing|write|writing)(?: (?:it|that|this))?[, ]+(?:just|but|instead|rather|and)[, ]+(.+)$"#) {
            return classify(m[1], in: ctx, allowHold: false)
        }

        if ctx.dictating, unprefixed.matches(#"^(?:cancel|forget|scratch|undo|delete|remove) (?:that|it|this)$"#) { return .edit }
        if isStop(l) { return .stop }

        // 2. "Oh no, that's wrong, undo": an outburst, then a command — the command counts.
        if let tail = commandAfterInterjection(l) {
            let intent = classify(tail, in: ctx, allowHold: false)
            switch intent {
            case .stop, .keys, .edit: return intent
            default: break
            }
        }

        if l.matches(#"^(?:start|keep|continue|resume|begin) (?:typing|dictating|dictation|writing)(?: here| now| in here)?$|^take (?:a )?dictation$"#) { return .startDictation }
        // 3. "type …": what follows is text, whatever words it contains. ("Thai, …", "Typ, …": how "type" is often heard.)
        if raw.lowercased().matches(#"^(?:in (?:this|the) \S+[, ]+)?(?:type|typ|taip|write|dictate)[.,!]?$"#) { return allowHold ? .hold : .ignore }
        let typedText = text.replacingOccurrences(of: #"^(?i)(?:in (?:this|the) (?:note|field|box|message|chat|document|doc|cell|text box|search box|email|mail)[, ]+)?(?:(?:typ|taip|thai|tie|tai)[,:]|(?:thai|tie|tai) pin|(?:right|write|note|node|jot) (?:it |this |that )?down[,:]?)\s+"#, with: "type ", options: .regularExpression)
            .replacingOccurrences(of: #"^(?i)(?:in|into|on) (?:this|the) (?:note|field|box|message|chat|document|doc|cell|text box|search box|email|mail)[, ]+(?=(?:type|write|dictate)\b)"#, with: "", options: .regularExpression)
        let typingVerb = !typedText.lowercased().matches(#"^type (?:\d{1,2} \S+ \S+|of\b|is\b|was\b|about\b)|^write (?!down\b|in it\b|into it\b|in there\b|here\b|this\b|that\b)"#)
        // "write a polite reply saying…", "draft an email to…": Hark is to compose it — the writing model decides.
        if !typingVerb, typedText.lowercased().matches(#"^(?:write|draft|compose) (?:a|an|the|me a|me an) "#) { return .askFirst }
        if typingVerb, let typed = CommandParser.typedPart(typedText) {
            // "type heading as Introduction", "type thanks in bold": words plus formatting — the writing model plans both.
            let t = lower(typed)
            if t.matches(#"^(?:a |the )?(?:heading|title|subheading|subtitle|bullet|bullet point|checkbox|check box|bold|italic|list item) (?:as|called|saying|that says|with)\b"#)
                || t.matches(#"\b(?:in|as) (?:bold|italics?|underline|a heading|heading|a title|a subheading|a bullet|bullets|a list|a checklist)$"#) { return .edit }
            let (words, then) = splitTrailingCommand(typed)
            let rendered = Dictation.render(words, after: ctx.previous)
            if rendered.isEmpty { return then == nil ? .hold : .request }
            return .words(rendered, then: then)
        }

        // Hark asked something a moment ago ("delete that line or replace it?"): an answer-shaped reply answers it.
        if ctx.harkAsked, l.matches(#"^(?:yes|yeah|yep|no|nope|sure|okay|ok|both|neither|either|go ahead|do it|do that|the (?:first|second|third|last|other|top|bottom) (?:one|option)|that one|this one|option (?:\w+)|number \w+|\d+|first|second|third|the first|the second)(?:[, ]+(?:please|one|do it|go ahead|thanks))*$"#) { return .request }
        // 4. Keys, punctuation, fillers, lone connectives.
        if let (combo, times) = keyCombo(l) { return .keys(combo, times: times) }
        if l.matches(#"^(?:select all|copy|paste|undo|cut)(?: (?:that|it|the text))?[, ]+(?:and |then |and then )+\S"#) { return .edit }
        if l.matches(#"^(?:(?:go |move )?(?:in|on|to|into) )?(?:the |a )?(?:next|new|another|fresh) (?:line|paragraph|para)$"#) {
            return .punctuation(l.hasSuffix("line") ? "\n" : "\n\n")
        }
        if Dictation.isOnlySymbols(text) { return .punctuation(Dictation.render(text, after: ctx.previous)) }
        if allowHold, l.matches(#"\b(?:as|to|the|a|an|of|with|for|from|and|or|called|named|saying|into|in)$"#), isCutOff(l, dictating: ctx.dictating) { return .hold }
        // Short commands as speech-to-text hears them through a cold or an accent: "dew line", "full stock", "next sell".
        if let heard = soundsLikeCommand(l) { return heard }
        if l.matches(#"^(?:(?:acha|achha|accha|haan|han|ha|ji|theek hai|thik hai|theek|thik|hmm|arey|are|yaar|yar|ok|okay)[, ]*)+$"#) { return .ignore }
        if CommandParser.isFiller(l) {
            // "yes" after "the answer is" is the answer; a lone "yeah" is not for Hark.
            let pure = Dictation.fillers.contains(l)
            return ctx.dictating && !pure && endsWithDangler(lower(ctx.recentText)) ? words(text, ctx) : .ignore
        }
        if allowHold, raw.lowercased().matches(#"^(?:(?:and|then|so|but|or|also|because|plus|and also)[ ,.]*)+$"#) { return .hold }
        // "can you", "do one thing", "I want you to": the request is still coming.
        if allowHold, l.matches(#"^(?:(?:here|so|okay|please|hey) )?(?:can you|could you|would you|will you|can you please|could you please|i want you to|i need you to|do one thing|one thing|listen|look|hark|hey hark|so basically|what i want is)$"#) { return .hold }
        // An instruction cut off on "as", "to", "the"… ("Retype heading as") waits for the rest before it's read.
        if allowHold, l.matches(#"\b(?:as|to|the|a|an|of|with|for|from|and|or|called|named|saying|into|in)$"#), isCutOff(l, dictating: ctx.dictating) { return .hold }

        // "new line and then make it bold": a step about the text after the words — the writing model plans both.
        if let m = l.firstMatch(#"^(.+?)[, ]+(?:and then|then|and after that|and)[, ]+((?:make|turn|put|bold|italicize|underline|capitalize|delete|remove|select|send|submit|press|hit) .+)$"#), m[2].split(separator: " ").count <= 9 {
            switch classify(m[2], in: Context(kind: ctx.kind, dictating: true, recentText: ctx.recentText), allowHold: false) {
            case .edit, .keys: return .edit
            default: break
            }
        }
        // 5. Complaints about what Hark did; then corrections and formatting, which are always about the text.
        if isTakeBack(unprefixed) { return .edit }
        if isComplaint(l) || isComplaint(unprefixed), !ctx.dictating || l.split(separator: " ").count <= 10 || isQuestion(l) { return .request }
        if isCorrection(unprefixed, ctx) { return .edit }
        if l.matches(#"\b(?:rows?|columns?|cells?|sheets?|tabs?)\b"#), isAppOperation(stripOpener(l), dictating: false),
           !ctx.dictating || ctx.kind == .cell || l.split(separator: " ").count <= 8 || l.matches(#"\bthis (?:google )?(?:sheet|spreadsheet|tab)\b"#) { return .request }
        if hasFormattingWord(l), !(ctx.dictating && hasSpokenSymbols(text) && l.split(separator: " ").count >= 6) { return .edit }

        // 6. Addressed to Hark by name: an edit, or a request — never dictation.
        if addressed { return isEditInstruction(l, ctx) ? .edit : .request }

        // 7. Instructions about the text: an edit verb aimed at the text itself.
        if isEditInstruction(l, ctx) { return .edit }

        let core = stripOpener(l)
        let reader = toReader(core)
        if ctx.dictating {
            // 8. While dictating, words are text — even imperatives to the message's reader — unless they are clearly for Hark.
            // A sentence that stops on "is", "the", "to"… waits for the rest first, so it's read and typed as one.
            if allowHold, isCutOff(l, dictating: true) { return .hold }
            if reader || (hasSpokenSymbols(text) && l.split(separator: " ").count >= 5) { return words(text, ctx) }
            // "Click here to register", "Click the link below to…": a call to action in the text, not a click.
            if core.matches(#"^(?:click|tap|press) (?:here|the link|this link|below|the button below|on the link)\b"#) { return words(text, ctx) }
            let long = core.split(separator: " ").count > (core.matches(#"\bthis (?:google )?(?:sheet|spreadsheet|tab|window|page|screen|doc|document|file|chat|note)\b"#) ? 14 : 8)
            if !long, isHarkAction(core, ctx) || isMacWork(core, ctx) { return core.matches(#"^(?:create|make|start|add) (?:a )?new\b|\bmy screen\b"#) ? .askFirst : .request }
            if !long, isAppOperation(core, dictating: true) { return .request }
            if core.matches(#"^(?:send|forward|share) (?:this|it|that) (?:to|with) \S"#) { return .askFirst }
            if l.matches(#"^(?:thai|tie|tai|die|tight) \S+(?: \S+){0,3}$"#) { return .askFirst }
            if isQuestion(l), l.matches(#"^(?:is|does|was|did|will|would|should|can) (?:this|that|it)\b.*\b(?:too|okay|ok|right|correct|good|fine|clear|formal|polite|professional|long|short|enough)\b"#) { return .askFirst }
            if core.matches(#"^(?:remind me|set (?:a |an )?(?:timer|alarm|reminder)|schedule a)\b"#) { return .askFirst }
            if l.matches(#"^(?:i need you to|i want you to|i'd like you to|i would like you to)\b"#) || l.matches(#"^(?:that|this|it) (?:doesn't|does not|don't) (?:sound|look|seem|read)\b"#) { return .askFirst }
            if allowHold, isCutOff(l, dictating: true) { return .hold }
            // An order about the text or the app ("add eggs to the list", "send the prompt", "close that tab"): for the reader,
            // or for Hark? The writing model decides, with the text in front of it, before anything is typed. Orders about the
            // world ("Please recharge using the wallet", "Bring the charger") are the message itself.
            if isImperative(core), !isPoliteContent(core), core.matches(textOrAppThings) || core.split(separator: " ").count <= 3 { return .askFirst }
            if isQuestion(l), l.matches(#"\b(?:you|hark)\b"#), l.split(separator: " ").count <= 8, !isGreeting(l) { return .askFirst }
            return words(text, ctx)
        }

        // 9. No dictation open: what can only be for Hark is for Hark.
        if isHarkAction(core, ctx) || isMacWork(core, ctx) || isQuestionForHark(l) || isAppOperation(core, dictating: false) { return .request }
        if ctx.kind == .cell, l.matches(#"\b(?:rows?|columns?|cells?|sheets?|column [a-z]|row \d+|cell [a-z]+\d+)\b"#) { return .request }
        if isImperative(core), isRequestVerb(core), core.split(separator: " ").count >= 4, !toReader(core) { return .request }

        // 10. A sentence cut off by a pause waits for the rest.
        if allowHold, isCutOff(l, dictating: false) { return .hold }

        // 11. Asked of an agent ("can you…", "I want you to…"): Hark — unless it's plainly for the reader of a message.
        if l.matches(#"^(?:here[, ]+|so[, ]+|okay[, ]+|now[, ]+)?(?:(?:can|could|would|will) (?:you|u)|(?:i want|i need|i'd like|i would like) you to|go ahead and)\b"#) {
            return reader ? .askFirst : .request
        }
        if isGreeting(l) { return words(text, ctx) }
        // 12. An order ("Create a plan…", "Buy milk"): a request for Hark, or a to-do or message — the model decides.
        if isImperative(core) {
            return !reader && isRequestVerb(core) && ctx.kind != .area ? .request : .askFirst
        }

        // 13. Plain words with no dictation open: type them into a document or message; ask about anything else.
        if l.matches(#"\b(?:paragraph|sentence|heading|section|the text|the line|the title)\b"#), l.matches(#"\b(?:should|needs?|must|has to|have to|ought)\b"#) { return .askFirst }
        switch ctx.kind {
        case .area:
            if isQuestion(l), !isGreeting(l), !reader || l.matches(#"\b(?:you|hark)\b"#) && l.split(separator: " ").count <= 8 { return .askFirst }
            return words(text, ctx)
        case .cell, .singleLine:
            // A name, an amount, a search: short words with no verb are what a cell or a box wants.
            return l.split(separator: " ").count <= 5 && !l.contains(",") && !hasVerb(l) && !isQuestion(l) ? words(text, ctx) : .askFirst
        case .none: return .request
        }
    }

    static func words(_ text: String, _ ctx: Context) -> SpeechIntent {
        .words(Dictation.render(text, after: ctx.previous), then: nil)
    }

    /// "send it", "send", "send the message", "submit".
    public static func isSend(_ phrase: String) -> Bool {
        let l = stripOpener(lower(phrase))
        return l.matches(#"^(?:send|submit|post|run|execute|fire off|ship)(?: it| this| that| the (?:prompt|message|reply|mail|email|command|query|text|draft)| now| it now| it off| this one)?$"#)
            || l.matches(#"^(?:okay |ok |yes |yeah )?(?:i think )?(?:this|it|that)(?:'s| is| one's| one is) (?:good|ready|fine|okay|ok) to (?:send|go|submit)$"#)
            || l.matches(#"^(?:full stop|period|question mark)(?: and)? (?:send|send it|submit)$"#)
    }

    // MARK: Normalizing

    static func lower(_ text: String) -> String {
        var l = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[.!?;:]+(\s|$)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s*,\s*"#, with: ", ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
        // How speech-to-text hears a few command words.
        l = l.replacingOccurrences(of: #"\bcapital ?(?:i[sz]e|ice|eyes|eyes)\b"#, with: "capitalize", options: .regularExpression)
            .replacingOccurrences(of: #"\b(this|the|a|new|current|next|previous|that|my) (?:node)\b"#, with: "$1 note", options: .regularExpression)
            .replacingOccurrences(of: #"^(make|turn|set) (.+) (?:bowled|bolt|bald)$"#, with: "$1 $2 bold", options: .regularExpression)
            .replacingOccurrences(of: #"^(press|hit) (?:editor|inter|entre|enta)$"#, with: "$1 enter", options: .regularExpression)
            .replacingOccurrences(of: #"^school (down|up)\b"#, with: "scroll $1", options: .regularExpression)
        // Fillers at the ends never change the meaning (Hindi ones too: "arey", "acha", "yaar").
        l = l.replacingOccurrences(of: #"^(?:(?:uh|uhh|um|umm|erm|hmm|okay|ok|so|well|alright|and|also|then|oh|yeah|yep|yup|arey|are|acha|achha|accha|haan|han|ji|yaar|yar|bhai|matlab|basically|actually|listen|see)[, ]+)+"#, with: "", options: .regularExpression)
        l = l.replacingOccurrences(of: #"(?:[, ]+(?:please|okay|ok|thanks|thank you|for me|uh|um|yeah|yaar|yar|bro|man|dude|na|ji|bhai))+$"#, with: "", options: .regularExpression)
        l = l.replacingOccurrences(of: #"(?<!\bfor|\buntil|\btill|\bby|\bfrom)[, ]+(?:right )?now$"#, with: "", options: .regularExpression)
        return l.trimmingCharacters(in: .whitespaces)
    }

    /// "please", "can you", "now"… in front of a request: what's left is the request itself.
    static let openers = #"^(?:(?:here|so|okay|ok|please|just|now|then|go ahead and|go and|can you|could you|would you|will you|can u|i want you to|i need you to|i'd like you to|i would like you to|you should|you need to|you can|let's|lets|kindly|hark)[, ]+)+"#

    static func stripOpener(_ l: String) -> String {
        l.replacingOccurrences(of: openers, with: "", options: .regularExpression)
    }

    /// "Hark, …", "hey Hark …", "Hark open …": the rest is for Hark. "Hark is working" is just a sentence.
    static func stripAddress(_ raw: String) -> (String, Bool) {
        if let m = raw.firstMatch(#"^(?i)(?:hey|hi|ok|okay|yo)[, ]+(?:hark|hawk|hack|arc|harp|hark's)[,.:!]?\s*(.*)$"#) { return (m[1], true) }
        if let m = raw.firstMatch(#"^(?i)(?:hark|hawk|hark's)[,.:!]\s*(.*)$"#) { return (m[1], true) }
        if let m = raw.firstMatch(#"^(?i)hark\s+(.+)$"#), lower(m[1]).matches("^(?:" + imperativeWords + #")\b"#) { return (m[1], true) }
        return (raw, false)
    }

    static let imperativeWords = #"please|can|could|would|will|stop|type|write|open|close|quit|send|click|tap|press|scroll|look|check|read|find|search|play|pause|create|make|fill|add|delete|remove|clear|undo|select|copy|paste|cut|go|show|take|tell|set|turn|summarize|translate|explain|start|run|save|download|reply|forward|share|move|put|insert|replace|change|fix"#

    // MARK: Stop

    static let stopPhrase = #"(?:stop|quit|cancel|enough|abort|halt)(?:[ ,]+(?:it|that|this|now|typing|writing|dictating|dictation|listening|everything|please|right there|there|hark))*|(?:that'?s|that is|this is) (?:enough|it|all)(?: for now)?|never mind|nevermind|forget it|leave it|hold on|shut up|be quiet|stop talking|stop listening|no more"#

    /// "stop", "stop typing", "don't type", "no no don't type", "stop typing you idiot", "that's enough, stop listening".
    public static func isStop(_ l: String) -> Bool {
        let s = l.replacingOccurrences(of: #"^(?:(?:no|wait|hey|oh|okay|ok|please|hark|hawk|dude|bro|man|arey|are)[, ]+)+"#, with: "", options: .regularExpression)
        if s.matches("^(?:(?:" + stopPhrase + ")(?:[ ,]+|$))+$") { return true }
        // Hindi: "bas", "bas bas", "ruko", "rehne do", "chhodo".
        if s.matches(#"^(?:(?:bas|bus|ruko|rukho|ruk jao|ruk|chhodo|chodo|rehne do|rahne do|bas karo|bus karo|ho gaya bas)[ ,]*)+$"#) { return true }
        if s.matches(#"^(?:that'?s (?:it|enough|all)|enough)[, ]+(?:bas|bus|stop|stop it|stop typing|thanks|done)$"#) { return true }
        // "stop typing …" / "stop filling the rows": stopping what Hark is doing, however the sentence goes on.
        if s.matches(#"^(?:stop|quit|cancel|abort|pause|halt) (?:the )?(?:typing|tiping|taping|tying|writing|dictating|dictation|listening|listing|filling|fill|clicking|scrolling|searching|deleting|sending|reading|doing (?:that|it|this)|it right now|it now|everything)\b"#) { return true }
        if s.matches(#"^(?:never mind|nevermind|forget it|forget about it)\b"#) { return true }
        // "don't type", "don't type that": not "don't write to the production database".
        if s.matches(#"^(?:don'?t|do not|never|please don'?t|dont) (?:\S+ )?(?:type|typed|types|tide|tied|tie|taip|thai|write|dictate|transcribe)(?:$| (?:that|this|it|anything|any more|anymore|here|there|again|yet|this time|in here|in there|so fast|everything|what i say|what i'm saying|all this|my (?:password|pin|otp|code|email|number|name|details|card)|in (?:the|this|here|there) \S+)\b)"#) { return true }
        if s.matches(#"^(?:okay |ok )?(?:that'?s it[, ]+)?(?:i'?m|i am) (?:done|finished) (?:dictating|typing|writing|talking)$|^done (?:dictating|typing)$"#) { return true }
        if s.matches(#"^(?:i'?ll|i will|let me|i'm going to|i am going to|i can) (?:just )?(?:type|write) (?:it|this|that)(?: myself| by myself| on my own)?$"#) { return true }
        if l.matches(#"^(?:no[ ,]*){2,}(?:stop|wait|hold on)?[ ,]*$"#) { return true }
        return false
    }

    // MARK: Keys

    static let shortcuts: [String: KeyCombo] = [
        "undo": KeyCombo(key: "z", command: true), "undo that": KeyCombo(key: "z", command: true), "undo it": KeyCombo(key: "z", command: true),
        "redo": KeyCombo(key: "z", command: true, shift: true), "redo that": KeyCombo(key: "z", command: true, shift: true),
        "select all": KeyCombo(key: "a", command: true), "select everything": KeyCombo(key: "a", command: true), "select all text": KeyCombo(key: "a", command: true),
        "copy": KeyCombo(key: "c", command: true), "copy that": KeyCombo(key: "c", command: true), "copy it": KeyCombo(key: "c", command: true),
        "paste": KeyCombo(key: "v", command: true), "paste it": KeyCombo(key: "v", command: true), "paste that": KeyCombo(key: "v", command: true),
        "paste here": KeyCombo(key: "v", command: true), "paste the link": KeyCombo(key: "v", command: true), "paste the link i copied": KeyCombo(key: "v", command: true),
        "paste what i copied": KeyCombo(key: "v", command: true), "paste the text": KeyCombo(key: "v", command: true),
        "cut": KeyCombo(key: "x", command: true), "cut that": KeyCombo(key: "x", command: true), "cut it": KeyCombo(key: "x", command: true),
        "save": KeyCombo(key: "s", command: true), "save it": KeyCombo(key: "s", command: true), "save this": KeyCombo(key: "s", command: true),
        "backspace": KeyCombo(key: "delete"), "back space": KeyCombo(key: "delete"), "delete": KeyCombo(key: "delete"), "delete key": KeyCombo(key: "delete"),
        "tab": KeyCombo(key: "tab"), "tab key": KeyCombo(key: "tab"), "escape": KeyCombo(key: "escape"), "esc": KeyCombo(key: "escape"),
        "enter": KeyCombo(key: "return"), "return": KeyCombo(key: "return"), "submit": KeyCombo(key: "return"),
        "space": KeyCombo(key: "space"), "spacebar": KeyCombo(key: "space"),
        "up arrow": KeyCombo(key: "up"), "down arrow": KeyCombo(key: "down"), "left arrow": KeyCombo(key: "left"), "right arrow": KeyCombo(key: "right"),
        "arrow up": KeyCombo(key: "up"), "arrow down": KeyCombo(key: "down"), "page up": KeyCombo(key: "pageup"), "page down": KeyCombo(key: "pagedown"),
        "next cell": KeyCombo(key: "tab"), "previous cell": KeyCombo(key: "tab", shift: true), "back a cell": KeyCombo(key: "tab", shift: true),
        "next row": KeyCombo(key: "down"), "go to the next row": KeyCombo(key: "down"), "down a row": KeyCombo(key: "down"),
        "previous row": KeyCombo(key: "up"), "up a row": KeyCombo(key: "up"), "next field": KeyCombo(key: "tab"), "previous field": KeyCombo(key: "tab", shift: true),
    ]

    /// One key or shortcut: "undo", "command z", "press command shift t", "hit enter".
    static func singleKey(_ unit: String) -> KeyCombo? {
        let u = unit.trimmingCharacters(in: .whitespaces)
        if let known = shortcuts[u] { return known }
        if let m = u.firstMatch(#"^(?:press|hit|tap|push)(?: the)? (.+?)(?: key| keys| button)?$"#) {
            return shortcuts[m[1]] ?? KeyCombo(spoken: m[1])
        }
        if u.matches(#"^(?:cmd|command|control|ctrl|option|opt|alt|shift)\b"#) { return KeyCombo(spoken: u) }
        return nil
    }

    /// A key or shortcut, maybe repeated: "command z, command z" → twice; "command z again"; "undo three times".
    public static func keyCombo(_ l: String) -> (KeyCombo, Int)? {
        // How speech-to-text hears key names: "come on z" / "comment z" = command z, "zid" / "zed" = z.
        let heard = l.replacingOccurrences(of: #"\b(?:come on|comment|commend|commands|command's|kamand|komand),?(?= (?:shift |option |control |alt )*(?:[a-z0-9]|zid|zed|zee|zet|enter|return|tab|delete|backspace|escape|space|up|down|left|right)\b)"#, with: "command", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\bcommand |\bcontrol |\boption |\bshift |\bcmd |\bctrl |\balt )(?:zid|zed|zee|zet|jed|jet|said)\b"#, with: "z", options: .regularExpression)
            .replacingOccurrences(of: #"\b(next|previous) sell\b"#, with: "$1 cell", options: .regularExpression)
        var tokens = heard.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        var times = 1
        // "… twice" / "… three times" / "… two more times" at the end.
        if tokens.last == "twice" { times = 2; tokens.removeLast() }
        else if tokens.count >= 2, tokens.last == "times" {
            let countWord = tokens[tokens.count - 2] == "more" && tokens.count >= 3 ? tokens[tokens.count - 3] : tokens[tokens.count - 2]
            guard let n = NumberWords.parse(countWord) ?? Int(countWord) else { return nil }
            times = n
            tokens.removeLast(tokens[tokens.count - 2] == "more" ? 3 : 2)
        }
        // Trailing "again" / "once more" mean the same key; a lone "again" after one key is still once.
        var agains = 0
        while let last = tokens.last, ["again", "more", "once"].contains(last) || (last == "and" && agains > 0) {
            if last == "again" { agains += 1 }
            tokens.removeLast()
        }
        guard !tokens.isEmpty else { return nil }
        for n in 1...min(5, tokens.count) where tokens.count % n == 0 {
            let unit = tokens[0..<n].joined(separator: " ")
            guard let combo = singleKey(unit) else { continue }
            var repeats = 0
            var ok = true
            for start in stride(from: 0, to: tokens.count, by: n) {
                if tokens[start..<start + n].joined(separator: " ") == unit { repeats += 1 } else { ok = false; break }
            }
            guard ok else { continue }
            let total = (times == 1 ? repeats : repeats * times) + (agains > 1 ? agains - 1 : 0)
            return (combo, max(1, min(total, 20)))
        }
        return nil
    }

    // MARK: Text instructions

    /// Formatting, selection and cursor words: never dictation on their own.
    static func hasFormattingWord(_ l: String) -> Bool {
        guard l.matches(#"\b(?:bold|italic|italics|italicize|italicise|underline|underlined|strikethrough|strike through|heading|subheading|title case|bullet|bullets|bulleted|numbered list|checklist|checkbox|indent|unindent|outdent|font size|font|highlight|caret|cursor|capitalize|capitalise|uppercase|lowercase|next item|new item|next bullet|new bullet|next point|new point)\b"#) else { return false }
        // "the heading", "my bold claim": a noun in a sentence, not an instruction.
        if l.matches(#"^(?:the|a|an|this|that|my|your|his|her|their|our|its|some|every|each|no|i|we|you|they|he|she) (?:\S+ )?(?:bold|heading|title|bullet|font|cursor|highlight|italic|indent|underline)s? (?:is|was|are|were|looks|seems|needs|has|had|reads|says|should|will|would|of|in|on|for|and|to|from|that|which)\b"#),
           !l.matches(#"^(?:this|that) (?:should|must|needs to|has to) be\b"#) { return false }
        // "Bold claims need bold evidence": an adjective in a sentence.
        if l.matches(#"^(?:bold|italic|underlined|highlighted) (?!that|it|this|the (?:last|first|word|line|sentence|title|heading))\S+ (?:need|needs|is|are|was|were|make|makes|get|gets|look|looks)\b"#) { return false }
        return true
    }

    /// Corrections of what was just dictated: "scratch that", "it's spelled H A R K", "that should be Hark with an H", "I meant sixty".
    /// "delete what you typed", "remove what you just wrote": take back what Hark typed.
    static func isTakeBack(_ l: String) -> Bool {
        l.matches(#"^(?:delete|remove|erase|undo|scratch|clear) (?:what|everything|all) (?:you|hark|it) (?:just )?(?:typed|wrote|put|entered|added)\b"#)
    }

    static func isCorrection(_ l: String, _ ctx: Context) -> Bool {
        if l.matches(#"^(?:scratch|strike) (?:that|this|the)\b"#) { return true }
        if l.matches(#"^(?:the )?(?:first|last|second|third|next|previous|top|bottom|opening|closing) (?:line|word|sentence|paragraph|bit|part) (?:should|needs to|has to) (?:say|be|read)\b"#) { return true }
        if l.matches(#"^(?:scratch|strike|erase|undo|retype|redo|drop|delete|remove) (?:that|this|it|the last (?:one|bit|line|sentence|word|thing|part|phrase)|what i (?:just )?(?:said|typed|wrote))$"#) { return true }
        if ctx.dictating, l.matches(#"^(?:cancel|forget) (?:that|it)$"#) { return true }
        if l.matches(#"^(?:start|begin) (?:again|over|afresh|from scratch|fresh)$"#) || l == "from the top" { return true }
        if l.matches(#"\b(?:is |it's |its |it is |that's |that is )?spelled?(?: as| like| with)? (?:[a-z] ){1,}[a-z]$"#) { return true }
        if l.matches(#"^(?:that|this|the last word|that word|that name)(?:'s| is)? (?:should be|was supposed to be|is supposed to be|was meant to be|meant to be|needs to be)(?: \S+){1,4}$"#) { return true }
        if ctx.dictating, l.matches(#"^(?:no[, ]+|sorry[, ]+|i mean[, ]+|i meant[, ]+)+(?:i meant |i mean |make it |change it to |it's |it is |not \S+, )\S"#) { return true }
        if ctx.dictating, l.matches(#"^(?:i meant|i mean|i said|not that)\b"#) { return true }
        return false
    }

    static let textReferents = #"(?:(?:this|that|these|those) (?:word|words|line|lines|sentence|sentences|paragraph|paragraphs|item|items|bullet|part|bit|phrase|letter|letters)|that|it|this|those|these|everything|all of it|all the text|the whole thing|the (?:last|previous|first|second|third|next|whole|entire|current|other)(?: (?:two|three|four|five|few|couple of|\d+))? (?:word|words|line|lines|sentence|sentences|paragraph|paragraphs|item|items|bullet|bullets|point|points|bit|part|character|characters|letter|letters|phrase|thing|one)|the (?:word|words|line|sentence|paragraph|text|phrase|title|list|item|bullet|selection|bracket|brackets|quote|quotes|comma|full stop|parenthesis|spelling|grammar|typo|typos|punctuation|formatting|capitalization|capitalisation)|what i (?:just )?(?:said|typed|wrote|dictated)|from \S+ to \S+|everything (?:after|before|from)|the (?:text|part) (?:after|before|from))"#

    static let editVerbs = #"(?:select|highlight|delete|remove|erase|clear|cut|copy|paste|replace|change|swap|put|make|turn|set|wrap|capitali[sz]e|move|insert|add|fix|correct|spell|strike|drop|scratch|retype|rewrite|reword|rephrase|format|join|merge|split|shorten|expand)"#

    /// Instructions about the text itself: the edit verb's object is the text ("delete the last line", "put that in
    /// brackets"), a word that is in the text ("replace tomorrow with Friday"), or a place in it ("go to the end").
    /// Text the user can point at by name: a line, a word, a comma, the message box.
    static let textParts = #"\b(?:(?:the |last |first |next |previous |that |this |a )line|lines|(?:the |last |first |that |this |a )word|words|sentence|sentences|paragraph|paragraphs|para|comma|commas|full stop|full stops|question mark|exclamation mark|colon|semicolon|quotes|quotation marks|quote marks|bracket|brackets|parentheses|space between|extra space|double space|typo|typos|spelling|message box|text box|chat box|search box|the text|all the text|the draft|page break|line break|new line|at the end|the beginning|the start)\b"#

    static func isEditInstruction(_ l: String, _ ctx: Context) -> Bool {
        let s = stripOpener(l)
        if s.matches(#"^(?:comment out|uncomment|indent|outdent|unindent|wrap|put|format|make|turn) .*\b(?:backticks|code block|inline code|a code|bullet points|bullets|a list|numbered list|a table|emoji)\b"#) { return true }
        if s.matches(#"^(?:comment out|uncomment) \S"#) { return true }
        if s.matches(#"^(?:add|insert|put) .{1,40} (?:to|in|into|on) (?:the|my|this) (?:list|note|checklist|message|email|draft|document|doc)$"#) { return true }
        if let m = s.firstMatch(#"^(?:it would be nice to|it'd be nice to|maybe|let's|lets|we should|i'd like to|could we) (.+)$"#), isEditInstruction(m[1], ctx) { return true }
        // "Delete last line", "add a comma after Akash", "put quotes around that", "clear the message box".
        if s.matches(#"^(?:delete|remove|erase|clear|add|insert|put|place|fix|correct|change|replace|capitalize|capitalise|select|highlight|move|join|merge|split|cut|copy|undo)\b"#), s.matches(textParts),
           !s.matches(#"\b(?:you|your|me|us|him|her|them)\b"#) || s.matches(#"\bwhat you (?:just )?typed\b"#),
           !ctx.dictating || s.split(separator: " ").count <= 8 && !s.matches(#"(?:full stop|comma|question mark|exclamation mark|new line|new paragraph|period)$"#) { return true }
        if s.matches("^" + editVerbs + #" (?:all )?(?:of )?"# + textReferents + #"(?:$|[, ]+(?:in|into|to|with|as|from|and|then|so|bold|italic|again|too|up|out|down|instead|please|now|for me)\b)"#) { return true }
        if s.matches(#"^(?:clear|empty) (?:it|this|that|everything|all|the (?:field|box|text|message|note|draft|input))$"#) { return true }
        if s.matches(#"^(?:go|move|jump|put the cursor|cursor|caret)(?: to| back to)? (?:the )?(?:very )?(?:end|beginning|start|top|bottom)(?: of (?:the )?(?:line|text|document|message|field|note|paragraph|sentence|word))?$"#) { return true }
        if let m = s.firstMatch(#"^(?:go|move|jump)(?: the cursor)? (?:to|after|before|back to) (?:the (?:word|words) )?(\S+)$"#), mentioned(m[1], ctx) { return true }
        // "replace tomorrow with Friday", "change ninety to sixty": an edit when the old words are in the text.
        if s.split(separator: " ").count <= 7, let m = s.firstMatch(#"^(?:replace|change|swap|switch|correct|fix) (?:the word |the words |where it says )?(.+?) (?:with|to|for|into|by) (.+)$"#) {
            if mentioned(m[1], ctx) || ctx.recentText.isEmpty && m[1].split(separator: " ").count <= 2 && !ctx.dictating { return true }
        }
        if let m = s.firstMatch(#"^(?:delete|remove|erase|cut|select|highlight|bold|underline|italicize|capitalize|quote) (?:the word |the words |the line |the sentence )?(.+)$"#), mentioned(m[1], ctx) { return true }
        if s.matches(#"^(?:put|wrap|enclose) (?:that|it|this|those|these|the last \S+|\S+(?: \S+){0,3}) in (?:brackets|parentheses|parens|quotes|quotation marks|square brackets|curly brackets|double quotes|single quotes)$"#) { return true }
        if s.matches(#"^(?:make|turn|set|change|convert) (?:that|it|this|the last \S+|the whole thing) (?:into |to |in )?(?:a )?(?:heading|title|list|bullet|bullets|bold|italic|italics|capitals|caps|all caps|uppercase|lowercase|smaller|bigger|shorter|longer|formal|casual|a question)\b"#) { return true }
        if let m = s.firstMatch(#"^(?:make|turn|set|change) (?:the |this |that |these |those )?((?:\S+ ){0,2}?)(?:bigger|smaller|larger|bold|italic|italics|underlined|red|blue|green|black|a heading|a title|a list|bullets|uppercase|lowercase|all caps|capitals)$"#) {
            let object = m[1].trimmingCharacters(in: .whitespaces)
            if object.isEmpty || object.matches(#"^(?:title|heading|subheading|font|text|line|lines|paragraph|word|words|sentence|letters|first line|last line|first word|last word|whole thing|everything)$"#) || mentioned(object, ctx) { return true }
        }
        if s.matches(#"^(?:new|next|another) (?:line|paragraph) (?:after|before|here)\b"#) { return true }
        if s.matches(#"^(?:after|before) the (?:bracket|comma|quote|full stop|parenthesis|last word|word|colon)\b"#) { return true }
        return false
    }

    /// Whether `words` appear in the dictated text (so an instruction about them is an edit, not a sentence).
    static func mentioned(_ words: String, _ ctx: Context) -> Bool {
        let w = words.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased()
        guard !w.isEmpty, w.count <= 60, !ctx.recentText.isEmpty else { return false }
        let text = ctx.recentText.lowercased()
        if text.range(of: w) != nil { return true }
        // "tomato and potato" when the list has them on separate lines.
        let content = w.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !["and", "or", "the", "a", "an", "of", "to", "both", "also", "too"].contains($0) }
        return !content.isEmpty && content.count <= 6 && content.allSatisfy { text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: .regularExpression) != nil }
    }

    // MARK: Requests for Hark

    /// Complaints and questions about what Hark did: "it did not type", "nothing is typing", "what did you type".
    static func isComplaint(_ l: String) -> Bool {
        if l.matches(#"^(?:did|have) (?:you|hark|it) (?:just )?(?:type|typed|write|wrote|delete|deleted|send|sent|put)\b"#) { return true }
        // "it's typing in the cell again", "that went into the wrong cell", "it typed my last sentence twice".
        if l.matches(#"^(?:it|that|this|hark|you|the text|text)(?:'s| is| was| has| keeps| kept| just| still)? ?(?:typ\w*|went|put|added|deleted|removed|pasted|entered|got|is in|went in)\b.*\b(?:wrong (?:cell|place|field|box|note|window|chat|line|spot)|twice|again|in the cell|into the cell|in the sheet|everywhere|not deleted|still there)\b"#) { return true }
        if l.matches(#"^(?:it|that|this)(?:'s| is| was) (?:still )?not (?:typ|delet|remov|work|show|send|sent)\w*\b"#) { return true }
        if l.matches(#"^(?:it|you|hark) (?:typed|deleted|removed|pasted|sent|clicked) (?:my|the|it|that|this|everything)\b.*\b(?:twice|again|wrong|instead)\b"#) { return true }
        if l.matches(#"^(?:it|that|this|hark|the text|text|the words|my words)(?: still)? (?:isn't|is not|wasn't|was not|didn't|did not|doesn't|does not|won't|hasn't|has not|haven't|have not|never) (?:\S+ )?(?:typ|show|work|appear|go|register|happen|land|respond|listen|do|stop|come|get)\w*\b"#) { return true }
        if l.matches(#"^nothing (?:is |was |has |got )?(?:typ|show|work|appear|happen|land|com|go)\w*\b"#) { return true }
        if l.matches(#"\b(?:you|hark) (?:just )?(?:typed|didn't type|did not type|haven't typed|keep typing|keeps typing|kept typing|are typing|missed|skipped|ignored|aren't listening|are not listening)\b"#) { return true }
        if l.matches(#"\b(?:you|hark) (?:just )?(?:deleted|removed|erased|overwrote|replaced|wiped|cleared) (?:my|the text|everything|it|that|what i|all)\b"#) { return true }
        if l.matches(#"^i (?:asked|told|said to) you\b"#) || l.matches(#"\bi asked you to\b"#) { return true }
        if l.matches(#"^(?:what|why|where|how) (?:did|have|are|were|is|was) (?:you|hark|it) (?:just )?(?:type|typed|typing|done|doing|do|write|writing|wrote|written|put|putting|delete|deleting|deleted|send|sending|sent|open|opened|click|clicked|hear|heard|say|said)(?: (?:here|there|now|that|this|it))?$"#) { return true }
        if l.matches(#"^why (?:did|are|do|does|were|is|was) (?:you|hark|it|this|that) (?:\S+ )?(?:type|typ|writ|delet|send|sent|put|click|open|keep|ignor|stop|do|go|show)\w*"#) { return true }
        if l.matches(#"^(?:that'?s|that is|this is|it'?s|it is) not what i (?:said|meant|wanted|asked|typed|wrote)\b"#) { return true }
        if l.matches(#"^(?:no[, ]+)*(?:not|wrong) (?:in |into )?(?:the |that |this )?(?:cell|sheet|box|field|place|window|tab|chat|message|note)\b"#) { return true }
        if l.matches(#"^(?:no[, ]+)+(?:(?:not|wrong|in|into) )+(?:the |that |this )?(?:cell|sheet|box|field|place|window|tab|chat|message|note)\b"#) { return true }
        if l.matches(#"^(?:look at|check|see) (?:the |this |my )?screen\b"#) { return true }
        return false
    }

    /// Spoken to the reader of the message, not to Hark: "you"/"your", "send me", "by Friday".
    static func toReader(_ core: String) -> Bool {
        if core.matches(#"\b(?:you|your|yours|you'll|you're|you've|you'd|yourself|u)\b"#) { return true }
        if core.matches(#"\b(?:to me|for me|with me|from me|me the|me a|me an|me your|me some|me know|me if|me when|us the|us a|us know|tell him|tell her|tell them)\b"#) { return true }
        if core.matches(#"\bby (?:tonight|tomorrow|today|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week|this week|end of (?:day|the day|week|the week)|eod|noon|evening|morning)\b"#) { return true }
        return false
    }

    /// Things only Hark does with the message, the screen and the apps: "send it", "read it back", "click send", "open Chrome".
    static func isHarkAction(_ core: String, _ ctx: Context) -> Bool {
        if core.matches(#"^(?:send|submit|post|ship|fire off|send off) (?:it|this|that|the message|the email|the mail|the text|the reply|the draft|now|it now|it off|this message|the whole thing)?$"#) || core == "send" { return true }
        if core.matches(#"^read (?:it|this|that) (?:back|out|aloud)|^read (?:back|out) (?:what i (?:said|wrote|typed)|the message|it)|^read (?:me )?(?:the |this )?(?:screen|page|message)$"#) { return true }
        if core.matches(#"^(?:look at|check|see|show me|take a look at|have a look at|watch) (?:the |this |my |that )?(?:screen|page|sheet|window|tab|chat)\b"#) { return true }
        if core.matches(#"^(?:click|tap|double click|right click|press on) (?:on )?\S"#) { return true }
        if core.matches(#"^(?:scroll|swipe|page) (?:up|down|left|right|to the (?:top|bottom|end|start))(?: a bit| a little| more| again)?$"#) { return true }
        if core.matches(#"^(?:close|quit|minimi[sz]e|hide) (?:this|it|that|the window|the tab|this tab|this window|the app|this app)$"#) { return true }
        if core.matches(#"^(?:new tab|next tab|previous tab|go back|go forward|refresh|reload|zoom in|zoom out)$"#) { return true }
        if core.matches(#"^(?:now )?(?:search|google)(?: it| this| that| for it)?$"#) { return true }
        if let m = core.firstMatch(#"^(?:open|launch|switch to|go to|go back to|bring up) (?:the |my )?(.+?)(?: app| website| site| tab)?$"#) {
            let target = m[1]
            if target.contains(".") || ctx.isApp(target) { return true }
            if target.matches(#"^(?:new tab|next tab|previous tab|last tab|a new window|new window|settings|system settings|preferences|downloads|finder|terminal|spotlight|notification center|cell [a-z]+\d+|the previous note|the last note|the next note|a new note|new note|the chat with .+|chat with .+|.+'s chat)$"#) { return true }
        }
        if core.matches(#"^(?:go to|jump to|move to|select)(?: cell)? [a-z]{1,2} ?\d{1,5}$"#) { return true }
        if core.matches(#"^(?:take|grab|capture) (?:a )?(?:screenshot|screen shot|screen grab|picture of the screen)\b"#) { return true }
        if core.matches(#"^(?:create|make|start|open|add) (?:a )?new (?:note|document|doc|file|tab|window|message|email|mail|chat|sheet|spreadsheet|folder|event|reminder|page|slide)\b"#) { return true }
        if core.matches(#"^search (?:my |the |all |all my )?(?:notes|files|mail|email|emails|inbox|messages|chats|drive|docs|documents|downloads|desktop|computer|mac|slack|whatsapp) for\b"#) { return true }
        if core.matches(#"^(?:go back to|go to|open|switch to) (?:the )?(?:previous|last|next|first|other) (?:note|tab|window|chat|message|email|file|document|page|sheet)\b"#) { return true }
        if core.matches(#"^(?:open|show|close|hide|toggle) (?:the )?(?:command palette|palette|sidebar|side bar|menu|settings|preferences|terminal|console|inspector|developer tools|dev tools|downloads|history|bookmarks|extensions|panel|explorer)\b"#) { return true }
        if let m = core.firstMatch(#"^(?:open|launch|switch to|go to) (?:the |my )?([^,]+?)(?: app)? (?:and|then|,) "#), m[1].contains(".") || ctx.isApp(m[1]) || core.matches(#" and (?:send|share|forward|tell|message|reply|type|write)\b"#) { return true }
        if core.matches(#"^(?:what|which|how many) (?:mcp|mcps|servers|tools|connectors|apps|files|tabs|windows|rows|columns)\b"#) { return true }
        if core.matches(#"^what(?:'s| is) (?:the )?(?:time|date|day)(?: today| now| in \S+| right now)?$"#) || core.matches(#"^what time is it(?: in \S+(?: \S+)?| now| right now)?$"#) || core.matches(#"^what(?:'s| is) in (?:cell|the cell|column|row)\b"#) { return true }
        if core.matches(#"^(?:remind me|set (?:a |an )?(?:timer|alarm|reminder)|create a reminder)\b"#), !ctx.dictating { return true }
        return false
    }

    /// Work with the Mac's files and apps: "attach the invoice PDF from my downloads folder".
    static func isMacWork(_ core: String, _ ctx: Context) -> Bool {
        if core.matches(#"\bfrom (?:my |the )?(?:downloads|download folder|downloads folder|desktop|documents|drive|google drive|dropbox|icloud|computer|mac|laptop|files)\b"#),
           core.matches(#"^(?:attach|upload|send|share|open|add|insert|import|find|get|pick)\b"#) { return true }
        return false
    }

    /// Operations on the app's content as a whole: the sheet, the rows, a chart, this document. While dictating only
    /// unmistakable ones count ("clear this sheet"), not "please put the files in the shared folder".
    static func isAppOperation(_ core: String, dictating: Bool) -> Bool {
        let verbs = #"(?:fill|fill in|fill out|populate|generate|create|make|build|insert|add|put|enter|delete|remove|clear|empty|sort|sum|total|count|calculate|freeze|unfreeze|format|resize|rename|download|export|import|save|print|share|attach|upload|duplicate|copy|move|convert|autofill|merge|hide|unhide|filter|summari[sz]e|translate|explain|describe|analy[sz]e|check|compare|find|search|look up|highlight|color|colour|close|open|archive|star|pin|mute|forward|reply to)"#
        guard core.matches("^" + verbs + #"\b"#), !toReader(core) else { return false }
        let det = #"(?:(?:the|this|that|a|an|my|all|every|some|new|first|last|next|\d+|twenty|thirty|forty|fifty|hundred|a hundred|ten|five|two|three|four|empty|blank|whole|entire) ){0,3}"#
        let ui = #"(?:sheet|sheets|spreadsheet|cell|cells|column|columns|row|rows|header|headers|header row|table|tab|tabs|window|chart|graph|formula|formulas|sample data|dummy data|test data|slide|slides|pivot table)"#
        let content = #"(?:file|files|folder|document|doc|page|email|emails|mail|inbox|note|notes|chat|conversation|message|messages|pdf|image|photo|video|link|links|list|data|entries|records|draft)"#
        if core.matches(#"\b"# + det + ui + #"\b"#) { return !dictating || core.matches(#"\b(?:this|the|that|these|those|all|every|\d+|hundred|twenty|thirty|fifty|sample|dummy|new|a|an) "# + #"(?:\S+ )?"# + ui + #"\b"#) }
        if dictating { return core.matches(#"\b(?:this|that) (?:\S+ )?"# + content + #"\b"#) }
        return core.matches(#"\b"# + det + content + #"\b"#)
    }

    static let requestVerbs: Set<String> = [
        "open", "close", "quit", "launch", "run", "show", "hide", "click", "tap", "press", "scroll", "look", "check", "read", "find", "search",
        "google", "play", "pause", "skip", "mute", "unmute", "create", "fill", "delete", "remove", "clear", "download", "upload", "save", "send",
        "share", "reply", "forward", "schedule", "remind", "summarize", "summarise", "translate", "explain", "describe", "list", "count",
        "calculate", "sum", "total", "sort", "filter", "freeze", "rename", "generate", "navigate", "refresh", "reload",
        "zoom", "lock", "restart", "increase", "decrease", "raise", "lower", "screenshot", "record", "convert", "autofill", "populate", "export",
        "import", "print", "attach", "install", "uninstall", "reinstall", "update", "log", "sign", "go", "switch", "turn", "set", "minimize", "maximize",
    ]
    static let todoVerbs: Set<String> = [
        "buy", "call", "book", "order", "remember", "bring", "pick", "get", "take", "pay", "email", "text", "message", "finish", "review", "prepare",
        "write", "draft", "plan", "submit", "make", "meet", "clean", "ask", "tell", "confirm", "cancel", "fix", "test", "deploy", "build", "add",
        "put", "move", "change", "start", "stop", "try", "use", "keep", "let", "give", "bring", "follow", "visit", "wash", "cook", "feed", "water",
        "renew", "register", "apply", "contact", "invite", "collect", "drop", "return", "print", "sign", "share", "update", "talk", "discuss",
    ]

    /// Starts with a verb used as an order: "Fix the failing test", "Buy milk" — not "Meeting notes", "Slept badly".
    static func isImperative(_ core: String) -> Bool {
        guard let first = core.split(separator: " ").first.map(String.init), core.split(separator: " ").count >= 2 else { return false }
        if requestVerbs.contains(first) || todoVerbs.contains(first) { return true }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = core
        let (tag, _) = tagger.tag(at: core.startIndex, unit: .word, scheme: .lexicalClass)
        let (lemma, _) = tagger.tag(at: core.startIndex, unit: .word, scheme: .lemma)
        return tag == .verb && lemma?.rawValue.lowercased() == first
    }

    static func isRequestVerb(_ core: String) -> Bool {
        core.split(separator: " ").first.map { requestVerbs.contains(String($0)) } ?? false
    }

    /// Whether the words have a verb ("Akash Goyal" doesn't; "the totals look wrong" does).
    static func hasVerb(_ l: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = l
        var verb = false
        tagger.enumerateTags(in: l.startIndex..<l.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if tag == .verb { verb = true; return false }
            return true
        }
        return verb
    }

    /// Short commands that are often misheard, matched by sound: "dew line" → new line, "full stock" → full stop,
    /// "question bark" → ?, "next sell" → Tab, "scratched that" → scratch that, "said it" → send it.
    static let soundCommands: [(phrase: String, intent: SpeechIntent)] = [
        ("new line", .punctuation("\n")), ("next line", .punctuation("\n")), ("new paragraph", .punctuation("\n\n")),
        ("next paragraph", .punctuation("\n\n")), ("blank line", .punctuation("\n\n")), ("next para", .punctuation("\n\n")),
        ("full stop", .punctuation(".")), ("question mark", .punctuation("?")), ("open bracket", .punctuation("(")),
        ("close bracket", .punctuation(")")), ("exclamation mark", .punctuation("!")),
        ("next cell", .keys(KeyCombo(key: "tab"), times: 1)), ("scratch that", .edit), ("delete that", .edit),
        ("capitalize that", .edit), ("delete last line", .edit), ("send it", .request), ("send the message", .request),
        ("stop typing", .stop), ("don't type", .stop), ("scroll down", .request), ("scroll up", .request),
        ("scroll down a bit", .request), ("scroll up a bit", .request),
    ]

    static func soundsLikeCommand(_ l: String) -> SpeechIntent? {
        let words = l.split(separator: " ")
        guard (2...4).contains(words.count) else { return nil }
        let key = Vocabulary.soundKey(l)
        guard key.count >= 3 else { return nil }
        for (phrase, intent) in soundCommands where phrase.split(separator: " ").count == words.count {
            let target = Vocabulary.soundKey(phrase)
            let distance = AppCatalog.distance(key, target)
            // Same sound: it's the command. One sound off: the writing model decides, with the text in front of it.
            if distance == 0 { return intent }
            if distance == 1, target.count >= 4 { return .askFirst }
        }
        return nil
    }

    /// Things in the text or on the Mac — what an order to Hark is about, unlike an order to a person.
    static let textOrAppThings = #"\b(?:line|lines|word|words|sentence|sentences|paragraph|paragraphs|para|list|item|items|bullet|bullets|note|notes|prompt|code|function|block|comment|title|heading|font|emoji|backticks|quote|quotes|bracket|brackets|comma|space|draft|text|box|field|cell|cells|row|rows|column|columns|sheet|tab|tabs|window|app|folder|screen|page|link|button|menu|terminal|editor|browser|desktop|downloads|screenshot|chat|query|selection|cursor|caret)\b"#

    /// Orders that read as part of a message: "please find attached…", "let me know…", "feel free to…".
    static func isPoliteContent(_ core: String) -> Bool {
        core.matches(#"^(?:find|see|note|let me know|let us know|feel free|keep me|keep us|hope|have a|enjoy|take care|thank|thanks|congrats|welcome|remember to|don't forget|do let me|kindly (?:find|note|see)|bring|call me|text me|message me|ping me|email me|meet me|join us|come|wait for me|look forward|stay)\b"#)
    }

    static func isGreeting(_ l: String) -> Bool {
        l.matches(#"^(?:how are you|how's it going|how is it going|how have you been|how was your|what's up|whats up|hi|hello|hey|dear|good (?:morning|afternoon|evening|night)|thanks|thank you|hope you|congrats|congratulations|happy (?:birthday|anniversary|new year|diwali|holi|eid|holidays)|best regards|best wishes|kind regards|warm regards|regards|cheers)\b"#)
    }

    /// Questions only Hark would be asked, or questions to Hark about itself.
    static func isQuestionForHark(_ l: String) -> Bool {
        if endsWithDangler(l) { return false }
        if isQuestion(l), l.matches(#"^(?:what|which|how many|how much|when|where|who|why|how)\b"#) {
            // "how are you doing", "what are you up to": to a person.
            return !toReader(stripOpener(l)) || l.matches(#"\b(?:you|hark) (?:have|support|know|see|use|access|connect)\b"#) || l.matches(#"^(?:what|which) (?:mcp|mcps|servers|tools|models|connectors)\b"#)
        }
        if l.matches(#"^(?:do|can|could|will|would|are|have) you\b"#) {
            return !l.matches(#"\b(?:me|us|tonight|tomorrow|today|this week|next week|later|free|coming|around|available|busy|okay|ok|fine|there|home)\b"#)
        }
        return false
    }

    /// A question, by its shape.
    static func isQuestion(_ l: String) -> Bool {
        guard l.matches(#"^(?:what|why|where|when|who|which|how|whose|is|are|was|were|do|does|did|can|could|will|would|should|shall|has|have|had|may|might)\b"#) else { return false }
        // "what we need is…", "how you did it": a clause starting a sentence, not a question.
        return !l.matches(#"^(?:what|where|when|how|why|who|which) (?:i|we|they|he|she|you|it|people|everyone|nobody|somebody|the|a|an|my|your|our|their|this|that|these|those)\b"#)
    }

    // MARK: Fragments

    static let danglers: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from", "into", "onto", "about", "by", "as", "than",
        "and", "or", "but", "because", "if", "when", "while", "although", "though", "since", "unless", "until", "whether", "so that",
        "i", "we", "they", "he", "she", "who", "which", "whose", "my", "your", "our", "their", "his", "her", "its",
        "is", "are", "was", "were", "be", "been", "am", "have", "has", "had", "will", "would", "can", "could", "should", "must",
        "do", "does", "did", "very", "really", "more", "most", "not", "no", "every", "each", "some", "any", "this", "these", "those",
    ]

    static func endsWithDangler(_ l: String) -> Bool {
        guard let last = l.split(separator: " ").last else { return false }
        return danglers.contains(String(last).trimmingCharacters(in: .punctuationCharacters))
    }

    /// A sentence cut off by a pause: it ends on "the", "to", "and", "I", "is"…; or, with nothing written yet, it is a
    /// short verbless start ("The main reason", "In the second").
    static func isCutOff(_ l: String, dictating: Bool) -> Bool {
        let words = l.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 10 else { return false }
        // A spelled-out word ("it's S H R E Y A") ends on letters, not on "a".
        if words.count >= 2, words.suffix(2).allSatisfy({ $0.count == 1 }) { return false }
        if words.count <= 4, l.matches(#"^(?:when|because|if|although|though|since|unless|while|whereas|so that|and the|but the|and when|and if|so when)\b"#), !l.contains(",") { return true }
        // "tell him that", "I think that": what follows is the point.
        if l.matches(#"\b(?:tell|told|say|said|says|think|thought|know|knew|hope|believe|mean|guess|feel|realize|realise|heard|mention|mentioned|ensure|sure|remember|forget|notice|noticed|explain|explained) (?:\S+ )?that$"#) { return true }
        // "the main", "my first": the noun is still coming.
        if l.matches(#"\b(?:the|a|an|my|our|your|their|his|her|this|that) (?:main|best|other|same|whole|only|key|real|big|biggest|most|important|very)$"#) { return true }
        if l.matches(#"^(?:hi|hello|hey|thanks|thank you|dear|okay|ok|yes|no|good morning|good evening|good night|bye|cheers|regards|best|sure|done|great|fine|cool|nice|sorry|congrats|congratulations)\b"#), words.count <= 3 { return false }
        if endsWithDangler(l), !l.matches(#"\b(?:in|on|up|out|off|down|over|about|by|through|back|away|along|around|it|this|that|these|those)$"#), !isQuestion(l) { return true }
        if dictating { return false }
        if words.count == 1 { return CommandParser.isNoise(l) }
        guard words.count <= 3, l.matches(#"^(?:the|a|an|in|on|at|if|when|even|while|because|since|after|before|for|with|from|my|our|your|their|this|that|these|those|some|all|most|every|each|one|two|three|first|second|third|last|next|so|but|and)\b"#) else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = l
        var verb = false
        tagger.enumerateTags(in: l.startIndex..<l.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if tag == .verb { verb = true; return false }
            return true
        }
        return !verb
    }

    // MARK: Pieces

    /// Spoken punctuation in the phrase ("question mark", "comma"): someone dictating, not talking to Hark.
    static func hasSpokenSymbols(_ text: String) -> Bool {
        Dictation.tokenize(text).contains { token in
            if case .symbol(let s) = token { return s != "(" || text.lowercased().contains("open bracket") }
            return false
        }
    }

    /// "shit, that's wrong, undo" → "undo": the last clause after short interjections.
    static func commandAfterInterjection(_ l: String) -> String? {
        let parts = l.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 2, let last = parts.last else { return nil }
        let interjection = #"^(?:(?:no|nope|oh|oops|wait|sorry|damn|it|shit|ugh|hmm|god|my|man|dude|ok|okay|wrong|that's|that|is|not|right|stop|hey|hark|fuck|what|the|hell|come|on|bloody|arey|yaar|person|one|chat|name|again|seriously)[ ]?)+$"#
        guard parts.dropLast().allSatisfy({ $0.matches(interjection) }) else { return nil }
        return last
    }

    /// "hello world and then press enter" → ("hello world", "press enter"): a command after the typed words.
    static func splitTrailingCommand(_ typed: String) -> (String, String?) {
        guard let m = typed.firstMatch(#"^(.*?)[,.;]?\s+(?:(?:and )?then|and)\s+(.+)$"#) else { return (typed, nil) }
        let tail = lower(m[2])
        let core = stripOpener(tail)
        if keyCombo(tail) != nil || isStop(tail) || core.matches(#"^(?:send|submit|post) (?:it|this|that|the message|the email)$"#) || core == "send"
            || core.matches(#"^(?:open|close|switch to|go to|click|tap) \S"#) || hasFormattingWord(tail)
            || core.matches(#"^(?:make|turn|put) (?:it|that|this|them) (?:bold|italic|a heading|in brackets|in quotes|bigger|smaller)"#)
            || isAppOperation(core, dictating: false) || isHarkAction(core, Context(kind: .area, dictating: false)) {
            return (m[1], m[2])
        }
        return (typed, nil)
    }
}
