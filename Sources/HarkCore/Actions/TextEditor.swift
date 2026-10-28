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
            if let field = Self.capture(), replaceSelection(field, with: AX.spaced(text, before: Self.character(before: field))) {
                return "Type “\(Self.short(text))”"
            }
            await keyboardGate()
            try await Keyboard.type(text)
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

        case "delete", "remove", "erase" where op["text"] == nil && op["from"] == nil:
            // The selection: the Delete key works in every field, readable or not.
            await keyboardGate()
            try Keyboard.press(KeyCombo(key: "delete"))
            return "Delete"

        case "cut", "copy" where op["text"] == nil && op["from"] == nil:
            await keyboardGate()
            try Keyboard.press(KeyCombo(key: name == "cut" ? "x" : "c", command: true))
            return name == "cut" ? "Cut" : "Copy"

        case "delete", "remove", "erase":
            let field = try editable()
            let range = Self.tidy(try Self.target(op, in: field), in: field.text)
            let removed = (field.text as NSString).substring(with: range)
            guard range.length > 0 else { return "" }
            guard setSelection(field.element, range), replaceSelection(field, with: "", spaced: false) else {
                throw EditError.needsScreen("This field won't let me delete text.")
            }
            return "Delete “\(Self.short(removed))”"

        case "replace":
            let field = try editable()
            let range = try Self.target(op, in: field)
            let new = op["with"] as? String ?? ""
            guard setSelection(field.element, range), let fresh = Self.read(field.element), replaceSelection(fresh, with: new, spaced: false) else {
                throw EditError.needsScreen("This field won't let me change text.")
            }
            return "Replace with “\(Self.short(new))”"

        case "cut", "copy":
            let field = try editable()
            let range = try Self.target(op, in: field)
            let picked = (field.text as NSString).substring(with: range)
            let removing = name == "cut" ? Self.tidy(range, in: field.text) : range
            guard !picked.isEmpty else { throw EditError.notFound("the selection") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(picked, forType: .string)
            if name == "cut" {
                guard setSelection(field.element, removing), replaceSelection(field, with: "", spaced: false) else {
                    throw EditError.needsScreen("This field won't let me cut text.")
                }
            } else {
                _ = setSelection(field.element, range)
            }
            return "\(name == "cut" ? "Cut" : "Copy") “\(Self.short(picked))”"

        case "paste":
            guard let text = NSPasteboard.general.string(forType: .string) else { return "" }
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
