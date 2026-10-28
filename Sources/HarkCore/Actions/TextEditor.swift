import AppKit
import ApplicationServices

/// The text field you're working in, read through Accessibility: its text, and where the caret or selection is.
public struct TextField {
    let element: AXUIElement
    public var text: String
    /// UTF-16 range, like everything in AppKit; length 0 is a caret.
    public var selection: NSRange
    public let role: String
    public let label: String

    /// The text around the caret for the model: ⟦|⟧ marks the caret, ⟦…⟧ the selection.
    public func describe(budget: Int = 3000) -> String {
        let ns = text as NSString
        let start = max(0, selection.location - budget * 2 / 3)
        let end = min(ns.length, selection.location + selection.length + budget / 3)
        let before = ns.substring(with: NSRange(location: start, length: selection.location - start))
        let picked = ns.substring(with: selection)
        let after = ns.substring(with: NSRange(location: selection.location + selection.length, length: end - selection.location - selection.length))
        let marked = (start > 0 ? "…" : "") + before + (picked.isEmpty ? "⟦|⟧" : "⟦" + picked + "⟧") + after + (end < ns.length ? "…" : "")
        let kind = role == "AXTextArea" ? "multi-line text" : "single-line field"
        return "[Field] \(kind)\(label.isEmpty ? "" : " “\(label)”"), \(ns.length) characters\n[Text]\n\(marked)"
    }
}

public enum EditError: LocalizedError {
    /// The field can't be read or changed through Accessibility (a canvas editor, for one): let Claude use the screen.
    case needsScreen(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .needsScreen(let why): return why
        case .notFound(let text): return "I couldn't find “\(text)” in this text."
        }
    }
}

/// Carries out the edit steps the writing model plans: insert, select, move the caret, delete, replace, cut/copy/paste,
/// format. Text is found by quoting it, never by counting characters, and changed through Accessibility, so it lands
/// exactly and works mid-speech. Keystrokes (formatting, undo) wait until ⌥⌘ is released.
@MainActor
public final class TextEditor {
    public var keyboardGate: () async -> Void = {}

    public init() {}

    // MARK: Reading

    /// The focused editable element; with nothing focused, the window's main text area (e.g. a Notes body).
    public static func capture() -> TextField? {
        guard let app = AX.frontmostApp() else { return nil }
        if Browser.chromium.contains(app.localizedName ?? "") || app.bundleURL.map(AX.isElectron) == true { AX.enableWebAccessibility(app) }
        var element: AXUIElement?
        if let focused = AX.value(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
            let candidate = focused as! AXUIElement // swiftlint:disable:this force_cast
            if isEditable(candidate) { element = candidate }
        }
        // Nothing focused in Notes, TextEdit…: their main text area. Never on a web page, where it'd be a random box.
        if element == nil, !Browser.all.contains(app.localizedName ?? ""), let window = AX.focusedWindow(app), let area = AX.firstTextArea(in: window) {
            AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            element = area
        }
        guard let element else { return nil }
        return read(element)
    }

    /// What kind of field has focus: a spreadsheet cell, a one-line box (search, address bar, form, terminal), or a
    /// text area (a message, note, document, chat box). Speech is read differently in each: a cell rarely wants a sentence.
    public static func fieldKind() -> SpeechIntent.FieldKind {
        guard let app = AX.frontmostApp(), let focused = AX.value(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return .none }
        let element = focused as! AXUIElement // swiftlint:disable:this force_cast
        guard isEditable(element) else { return .none }
        let name = app.localizedName ?? ""
        if ["Numbers", "Microsoft Excel", "LibreOffice"].contains(name) { return .cell }
        let title = AX.focusedWindow(app).flatMap { AX.string($0, kAXTitleAttribute) } ?? ""
        if title.range(of: #"(?:Google Sheets|Excel|Numbers|Airtable|Smartsheet)\b"#, options: .regularExpression) != nil { return .cell }
        if ["Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty", "Hyper"].contains(name) { return .singleLine }
        let role = AX.string(element, kAXRoleAttribute) ?? ""
        let subrole = AX.string(element, kAXSubroleAttribute) ?? ""
        if ["AXTextField", "AXSearchField", "AXComboBox"].contains(role) || subrole == "AXSearchField" { return .singleLine }
        return .area
    }

    /// True when a text field has focus — speech about text then goes to the writing model.
    public static func isEditing() -> Bool {
        guard let focused = AX.value(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return false }
        return isEditable(focused as! AXUIElement) // swiftlint:disable:this force_cast
    }

    static func isEditable(_ element: AXUIElement) -> Bool {
        let role = AX.string(element, kAXRoleAttribute) ?? ""
        if AX.editableRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func read(_ element: AXUIElement) -> TextField? {
        guard let text = AX.string(element, kAXValueAttribute) else { return nil }
        var selection = NSRange(location: (text as NSString).length, length: 0)
        if let value = AX.value(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range) { // swiftlint:disable:this force_cast
                selection = NSRange(location: min(range.location, (text as NSString).length), length: range.length)
            }
        }
        let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
            .compactMap { AX.string(element, $0) }.first { !$0.isEmpty } ?? ""
        return TextField(element: element, text: text, selection: selection, role: AX.string(element, kAXRoleAttribute) ?? "", label: label)
    }

    // MARK: Finding text

    /// Where `needle` is in `text`: exact, then ignoring case, then ignoring spacing and punctuation differences.
    /// With several matches: "first", "last", a number, or (by default) the one nearest the caret.
    nonisolated public static func locate(_ needle: String, in text: String, near caret: Int, occurrence: String? = nil) -> NSRange? {
        let wanted = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var from = 0
        while from < ns.length {
            let found = ns.range(of: wanted, options: [.caseInsensitive], range: NSRange(location: from, length: ns.length - from))
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            from = found.location + max(found.length, 1)
        }
        if ranges.isEmpty {
            // Speech-model spacing and punctuation rarely match the page exactly.
            let words = wanted.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            guard !words.isEmpty else { return nil }
            let pattern = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"[^\p{L}\p{N}]+"#)
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                ranges = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            }
        }
        guard !ranges.isEmpty else { return nil }
        switch occurrence?.lowercased() {
        case "first": return ranges.first
        case "last": return ranges.last
        case let n? where Int(n) != nil: return ranges.indices.contains(Int(n)! - 1) ? ranges[Int(n)! - 1] : ranges.last
        default:
            return ranges.min { abs(Self.distance($0, caret)) < abs(Self.distance($1, caret)) }
        }
    }

    nonisolated private static func distance(_ range: NSRange, _ caret: Int) -> Int {
        if caret < range.location { return range.location - caret }
        if caret > range.location + range.length { return caret - range.location - range.length }
        return 0
    }

    /// The range an op points at: "text", or "from" … "to", or (with neither) the current selection.
    static func target(_ op: [String: Any], in field: TextField) throws -> NSRange {
        let caret = field.selection.location
        if let text = op["text"] as? String, !text.isEmpty {
            guard let range = locate(text, in: field.text, near: caret, occurrence: (op["occurrence"] as? String) ?? (op["occurrence"] as? Int).map(String.init))
            else { throw EditError.notFound(text) }
            return range
        }
        if let from = op["from"] as? String, let to = op["to"] as? String {
            guard let start = locate(from, in: field.text, near: caret) else { throw EditError.notFound(from) }
            let rest = (field.text as NSString).substring(from: start.location)
            guard let end = locate(to, in: rest, near: 0, occurrence: "first") else { throw EditError.notFound(to) }
            return NSRange(location: start.location, length: end.location + end.length)
        }
        return field.selection
    }

    // MARK: Doing

    /// Applies one op; returns a short label for the island. Throws `needsScreen` when Accessibility can't do it.
    public func apply(_ op: [String: Any], app: String, url: String?) async throws -> String {
        let name = (op["op"] as? String ?? "").lowercased()
        switch name {
        case "insert", "type", "write":
            let text = op["text"] as? String ?? ""
            guard !text.isEmpty else { return "" }
            _ = try await insert(text)
            return "Type “\(Self.short(text))”"

        case "select", "highlight":
            let field = try editable()
            let range = try Self.target(op, in: field)
            guard setSelection(field.element, range) else { throw EditError.needsScreen("This field won't let me select text.") }
            return "Select “\(Self.short((field.text as NSString).substring(with: range)))”"

        case "caret", "cursor", "move":
            let field = try editable()
            let ns = field.text as NSString
            var position = field.selection.location
            if let after = op["after"] as? String {
                guard let r = Self.locate(after, in: field.text, near: position, occurrence: op["occurrence"] as? String) else { throw EditError.notFound(after) }
                position = r.location + r.length
            } else if let before = op["before"] as? String {
                guard let r = Self.locate(before, in: field.text, near: position, occurrence: op["occurrence"] as? String) else { throw EditError.notFound(before) }
                position = r.location
            } else {
                switch (op["to"] as? String ?? "end").lowercased() {
                case "start", "beginning", "top": position = 0
                case "line_start", "start_of_line": position = ns.lineRange(for: NSRange(location: position, length: 0)).location
                case "line_end", "end_of_line":
                    let line = ns.lineRange(for: NSRange(location: position, length: 0))
                    position = line.location + line.length - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0)
                default: position = ns.length
                }
            }
            guard setSelection(field.element, NSRange(location: position, length: 0)) else { throw EditError.needsScreen("This field won't let me move the cursor.") }
            return "Cursor \(op["after"] != nil ? "after" : op["before"] != nil ? "before" : "to") \(Self.short((op["after"] ?? op["before"] ?? op["to"] ?? "end") as? String ?? ""))"

        // (A `where` after several patterns only guards the last one, so the selection case is checked inside.)
        case "delete", "remove", "erase":
            if op["text"] == nil && op["from"] == nil {
                // The selection: the Delete key works in every field, readable or not.
                await keyboardGate()
                try Keyboard.press(KeyCombo(key: "delete"))
                return "Delete"
            }
            let field = try editable()
            let range = Self.tidy(try Self.target(op, in: field), in: field.text)
            let removed = (field.text as NSString).substring(with: range)
            guard range.length > 0 else { return "" }
            guard try await change(range, in: field, to: "") else { throw EditError.needsScreen("This field won't let me delete text.") }
            return "Delete “\(Self.short(removed))”"

        case "replace":
            let field = try editable()
            let range = try Self.target(op, in: field)
            let new = op["with"] as? String ?? ""
            guard try await change(range, in: field, to: new) else { throw EditError.needsScreen("This field won't let me change text.") }
            return "Replace with “\(Self.short(new))”"

        case "cut", "copy":
            if op["text"] == nil && op["from"] == nil {
                await keyboardGate()
                try Keyboard.press(KeyCombo(key: name == "cut" ? "x" : "c", command: true))
                return name == "cut" ? "Cut" : "Copy"
            }
            let field = try editable()
            let range = try Self.target(op, in: field)
            let picked = (field.text as NSString).substring(with: range)
            let removing = name == "cut" ? Self.tidy(range, in: field.text) : range
            guard !picked.isEmpty else { throw EditError.notFound("the selection") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(picked, forType: .string)
            if name == "cut" {
                guard try await change(removing, in: field, to: "") else { throw EditError.needsScreen("This field won't let me cut text.") }
            } else {
                _ = setSelection(field.element, range)
            }
            return "\(name == "cut" ? "Cut" : "Copy") “\(Self.short(picked))”"

        case "paste":
            guard let text = Keyboard.clipboardString() else { return "" }
            return try await apply(["op": "insert", "text": text], app: app, url: url).replacingOccurrences(of: "Type", with: "Paste")

        case "format", "style":
            let style = (op["style"] as? String ?? "").lowercased()
            if let combo = Self.shortcut(for: style, app: app, url: url) {
                await keyboardGate()
                try Keyboard.press(combo)
                return style.capitalized
            }
            // Rich-text apps without heading styles (TextEdit, Mail): a heading is the line in bold, a size or two bigger.
            if Self.richTextOnly.contains(app), let steps = ["title": 3, "heading": 2, "subheading": 1][style], let field = Self.capture() {
                let ns = field.text as NSString
                var line = ns.lineRange(for: NSRange(location: field.selection.location, length: 0))
                if ns.substring(with: line).hasSuffix("\n") { line.length -= 1 }
                guard line.length > 0, setSelection(field.element, line) else { throw EditError.needsScreen("This field won't let me select the line.") }
                await keyboardGate()
                try Keyboard.press(KeyCombo(key: "b", command: true))
                for _ in 0..<steps { try Keyboard.press(KeyCombo(key: "=", command: true)) }
                _ = setSelection(field.element, NSRange(location: line.location + line.length, length: 0))
                return style.capitalized
            }
            // Plain text fields (and editors like Notion or GitHub): Markdown at the start of the line.
            guard let prefix = Self.markdown[style], let field = Self.capture() else {
                throw EditError.needsScreen("I don't know how to make \(style) in \(app).")
            }
            let ns = field.text as NSString
            let line = ns.lineRange(for: NSRange(location: field.selection.location, length: 0))
            guard setSelection(field.element, NSRange(location: line.location, length: 0)),
                  let atStart = Self.read(field.element), replaceSelection(atStart, with: prefix, spaced: false) else {
                throw EditError.needsScreen("This field won't let me add \(style).")
            }
            _ = setSelection(field.element, NSRange(location: field.selection.location + (prefix as NSString).length, length: 0))
            return style.capitalized

        case "key", "keys", "press":
            guard let combo = KeyCombo(spoken: op["keys"] as? String ?? "") else { return "" }
            await keyboardGate()
            try Keyboard.press(combo)
            return "Press \(combo)"

        case "undo":
            await keyboardGate()
            try Keyboard.press(KeyCombo(key: "z", command: true))
            return "Undo"

        default:
            return ""
        }
    }

    private func editable() throws -> TextField {
        guard let field = Self.capture() else { throw EditError.needsScreen("I can't read this text field.") }
        return field
    }

    /// Types `text` at the caret (replacing any selection); returns exactly what went in, with any space added before it.
    public func insert(_ text: String) async throws -> String {
        let field = Self.capture()
        let web = Self.isWebField()
        let before = field.flatMap { web && Self.caretNearEnd($0) ? $0.text.last : Self.character(before: $0) }
        let typed = field == nil ? text : AX.spaced(text, before: before)
        if !web, let field, replaceSelection(field, with: typed) { return typed }
        await keyboardGate()
        guard web, let field else {
            try await Keyboard.type(typed)
            return typed
        }
        // Web editors: key events, checked. Only a field that has shown typing before gets a phrase typed again —
        // others (a spreadsheet cell's hidden editor, a code editor) don't report their text, and retyping would double it.
        let reliable = Self.reflectsTyping.contains { CFEqual($0, field.element) }
        for attempt in 0..<2 {
            try Keyboard.typeLines(typed)
            if await Self.waitFor(field.element, { $0.text != field.text }) != nil {
                if !reliable { Self.reflectsTyping = Array(([field.element] + Self.reflectsTyping).prefix(8)) }
                break
            }
            guard reliable, attempt == 0 else {
                Log.info("Typed into a field that doesn't show its text; not checking it")
                break
            }
            Log.info("Typing didn't show up in the field; typing it again")
        }
        return typed
    }

    /// Fields whose Accessibility text has changed as Hark typed: there, a phrase that didn't show up can be retyped.
    static var reflectsTyping: [AXUIElement] = []

    /// Replaces the `count` characters before the caret with `text` by keys: ⇧← over them, then type over the
    /// selection in one step (⌫ only when `text` is empty) — never delete first, so typing that doesn't land loses
    /// nothing. For web editors, where an Accessibility selection lands late, at the wrong offset, and blocks pastes.
    /// If the change doesn't show, call `collapseSelection` so nothing stays selected.
    /// `expecting`: what the selection must be before it's replaced; if the field shows something else, nothing is
    /// changed (the selection is dropped) and this returns false.
    @discardableResult
    public func retypeBeforeCaret(_ count: Int, expecting old: String? = nil, with text: String) async throws -> Bool {
        await keyboardGate()
        for _ in 0..<count { try Keyboard.press(KeyCombo(key: "left", shift: true), quick: true) }
        if let old, count > 0, let element = Self.capture()?.element {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if let selected = AX.string(element, kAXSelectedTextAttribute), !selected.isEmpty,
               !Self.sameText(selected.replacingOccurrences(of: "\r", with: "\n"), old) {
                Log.info("Retype: selected “\(Self.short(selected))”, expected “\(Self.short(old))”; leaving it")
                try Keyboard.press(KeyCombo(key: "right"))
                return false
            }
        }
        if !text.isEmpty {
            try Keyboard.typeLines(text)
        } else if count > 0 {
            try Keyboard.press(KeyCombo(key: "delete"))
        }
        return true
    }

    /// After a change that didn't take: the caret back at the end of the selection it left, the text untouched.
    public func collapseSelection() async throws {
        await keyboardGate()
        try Keyboard.press(KeyCombo(key: "right"))
    }

    /// Chrome, Safari and Electron editors. Their Accessibility caret runs short (by about one per line break) and an
    /// Accessibility selection blocks the next paste, so Hark changes their text with keys from the caret instead.
    public static func isWebField() -> Bool {
        guard let app = AX.frontmostApp() else { return false }
        return Browser.all.contains(app.localizedName ?? "") || app.bundleURL.map(AX.isElectron) == true
    }

    /// In a web editor, whether the caret is at the end of the text, allowing for its short count.
    static func caretNearEnd(_ field: TextField) -> Bool {
        let length = (field.text as NSString).length
        let breaks = field.text.filter { $0 == "\n" }.count
        return field.selection.length == 0 && field.selection.location >= length - breaks - 1 && field.selection.location <= length
    }

    /// Where `written` sits: right before the caret. In a web editor the text must end with it (a line break the
    /// editor keeps after the last line doesn't count) and the caret be at the end; nil when it isn't there — you
    /// typed, deleted, or moved — so nothing of yours is ever changed.
    nonisolated public static func sessionRange(_ written: String, in text: String, selection: NSRange, web: Bool) -> NSRange? {
        guard !written.isEmpty, selection.length == 0 else { return nil }
        let ns = text as NSString, length = (written as NSString).length
        if !web {
            guard selection.location >= length else { return nil }
            let range = NSRange(location: selection.location - length, length: length)
            return sameText(ns.substring(with: range), written) ? range : nil
        }
        let breaks = text.filter { $0 == "\n" }.count
        guard selection.location >= ns.length - breaks - 1, selection.location <= ns.length else { return nil }
        let trailing = { (s: String) in String(s.reversed().drop { $0 == "\n" }.reversed()) }
        let core = trailing(text), mine = trailing(written)
        guard !mine.isEmpty ? sameText(String(core.suffix(mine.count)), mine) : true else { return nil }
        let start = (core as NSString).length - (mine as NSString).length
        return NSRange(location: max(0, start), length: length)
    }

    /// Changes `range` to `text` ("" deletes it); true only if the field's text really changed. Accessibility first.
    /// Web editors (WhatsApp, Slack…) often ignore Accessibility writes: then the range is selected — through
    /// Accessibility, or with ⇧← when it ends at the caret — and pasted over.
    func change(_ range: NSRange, in field: TextField, to text: String) async throws -> Bool {
        let original = field.text
        let end = NSRange(location: range.location + range.length, length: 0)
        // Web views (Chrome, Electron) apply an Accessibility selection a moment later, not at once.
        var fresh: TextField?
        if setSelection(field.element, range) {
            fresh = await Self.waitFor(field.element) { $0.selection == range }
        }
        if let fresh {
            if replaceSelection(fresh, with: text, spaced: false) { return true }
            Log.info("Change: selected through Accessibility; pasting over it")
        } else {
            // Selecting didn't take: only safe from the caret, backwards, over exactly this range.
            let now = Self.read(field.element)
            Log.info("Change: couldn't select \(range.location)+\(range.length) (selection now \(now.map { "\($0.selection.location)+\($0.selection.length)" } ?? "unknown"))")
            guard let now, now.selection == end else { return false }
            await keyboardGate()
            for _ in 0..<(original as NSString).substring(with: range).count { try Keyboard.press(KeyCombo(key: "left", shift: true)) }
        }
        await keyboardGate()
        if text.isEmpty { try Keyboard.press(KeyCombo(key: "delete")) } else { try await Keyboard.type(text) }
        let changed = await Self.waitFor(field.element) { $0.text != original } != nil || Self.read(field.element) == nil
        Log.info("Change: pasted over the range; text \(changed ? "changed" : "unchanged")")
        // Never leave text selected after a failed change: the next words typed would replace it.
        if !changed { _ = setSelection(field.element, field.selection) }
        return changed
    }

    /// Reads the field until `done` holds (up to about a second): web views update what Accessibility sees a moment later.
    static func waitFor(_ element: AXUIElement, _ done: (TextField) -> Bool) async -> TextField? {
        for attempt in 0..<12 {
            if let now = read(element), done(now) { return now }
            if attempt < 11 { try? await Task.sleep(nanoseconds: 80_000_000) }
        }
        return nil
    }

    /// The same text as far as an editor is concerned (web editors store some spaces as no-break spaces).
    nonisolated public static func sameText(_ a: String, _ b: String) -> Bool {
        a.replacingOccurrences(of: "\u{00A0}", with: " ") == b.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func setSelection(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// Replaces the selection (or inserts at the caret). Trusts it only if the text really changed.
    func replaceSelection(_ field: TextField, with text: String, spaced: Bool = true) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(field.element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        let before = AX.string(field.element, kAXValueAttribute)
        guard AXUIElementSetAttributeValue(field.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        if let before, let after = AX.string(field.element, kAXValueAttribute) { return after != before || (text.isEmpty && field.selection.length == 0) }
        return true
    }

    /// The last character before the caret that isn't a space ("\n" for a fresh line); `.some(nil)` at the start of the
    /// field. A web editor's caret count runs short, so there the end of the text is used when the caret is near it.
    public static func characterBeforeCaret(_ field: TextField) -> Character?? {
        let ns = field.text as NSString
        let caret = isWebField() && caretNearEnd(field) ? ns.length : min(field.selection.location, ns.length)
        let before = ns.substring(to: caret)
        guard let last = before.last(where: { $0 != " " && $0 != "\u{00A0}" && $0 != "\t" }) else { return .some(nil) }
        return .some(last)
    }

    static func character(before field: TextField) -> Character? {
        guard field.selection.location > 0 else { return nil }
        let ns = field.text as NSString
        return ns.substring(with: NSRange(location: field.selection.location - 1, length: 1)).first
    }

    static func short(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "↵ ")
        return flat.count > 36 ? String(flat.prefix(36)) + "…" : flat
    }

    // MARK: Formatting

    static let richTextOnly: Set<String> = ["TextEdit", "Mail", "Microsoft Outlook"]

    /// Removing a word shouldn't leave "on . " behind: take one neighbouring space along when the gap would double
    /// up or sit before punctuation.
    nonisolated static func tidy(_ range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        guard range.length > 0 else { return range }
        let end = range.location + range.length
        let before = range.location > 0 ? ns.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
        let after = end < ns.length ? ns.substring(with: NSRange(location: end, length: 1)) : ""
        if before == " ", after.isEmpty || after == " " || after == "\n" || ",.;:!?)".contains(after) {
            return NSRange(location: range.location - 1, length: range.length + 1)
        }
        if after == " ", before.isEmpty || before == "\n" { return NSRange(location: range.location, length: range.length + 1) }
        return range
    }

    static let markdown: [String: String] = [
        "heading": "# ", "title": "# ", "subheading": "## ", "bullet": "- ", "numbered": "1. ", "checklist": "- [ ] ", "quote": "> ",
    ]

    /// Each app's own shortcut for a style. Character styles are the same almost everywhere; paragraph styles aren't.
    static func shortcut(for style: String, app: String, url: String?) -> KeyCombo? {
        let k = { (key: String, mods: String) -> KeyCombo in
            KeyCombo(key: key, command: mods.contains("⌘"), option: mods.contains("⌥"), control: mods.contains("⌃"), shift: mods.contains("⇧"))
        }
        let docs = url?.contains("docs.google.com/document") == true
        switch (app, style) {
        case ("Notes", "title"): return k("t", "⇧⌘")
        case ("Notes", "heading"): return k("h", "⇧⌘")
        case ("Notes", "subheading"): return k("j", "⇧⌘")
        case ("Notes", "body"): return k("b", "⇧⌘")
        case ("Notes", "bullet"): return k("7", "⇧⌘")
        case ("Notes", "numbered"): return k("9", "⇧⌘")
        case ("Notes", "checklist"): return k("l", "⇧⌘")
        case ("Notes", "code"): return k("m", "⇧⌘")
        case ("Notes", "strikethrough"): return k("x", "⇧⌘")
        case ("Microsoft Word", "title"), ("Microsoft Word", "heading"): return k("1", "⌥⌘")
        case ("Microsoft Word", "subheading"): return k("2", "⌥⌘")
        case ("Microsoft Word", "body"): return k("n", "⇧⌘")
        case ("Microsoft Word", "bullet"): return k("l", "⇧⌘")
        case ("Slack", "strikethrough"): return k("x", "⇧⌘")
        case ("Slack", "code"): return k("c", "⇧⌘")
        case ("Slack", "bullet"): return k("8", "⇧⌘")
        case ("Slack", "numbered"): return k("7", "⇧⌘")
        case ("Slack", "quote"): return k("9", "⇧⌘")
        default: break
        }
        if docs {
            switch style {
            case "title", "heading": return k("1", "⌥⌘")
            case "subheading": return k("2", "⌥⌘")
            case "body": return k("0", "⌥⌘")
            case "bullet": return k("8", "⇧⌘")
            case "numbered": return k("7", "⇧⌘")
            case "checklist": return k("9", "⇧⌘")
            case "strikethrough": return k("x", "⇧⌘")
            default: break
            }
        }
        switch style {
        case "bold": return k("b", "⌘")
        case "italic": return k("i", "⌘")
        case "underline": return k("u", "⌘")
        default: return nil
        }
    }
}
