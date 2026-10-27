import AppKit
import ApplicationServices

public struct UIElementInfo: Sendable {
    public let role: String
    public let label: String
    public let frame: CGRect
}

public struct ScreenSnapshot: Sendable {
    public var appName: String = ""
    public var windowTitle: String = ""
    public var focusedRole: String = ""
    public var focusedValue: String = ""
    public var selectedText: String = ""
    public var browserURL: String = ""
    public var browserTitle: String = ""
    public var elements: [UIElementInfo] = []
    public var ocrText: String = ""

    /// Compact text for the language model.
    public func describe(maxElements: Int = 70) -> String {
        var lines = ["App: \(appName)"]
        if !windowTitle.isEmpty { lines.append("Window: \(windowTitle)") }
        if !browserURL.isEmpty { lines.append("Page: \(browserTitle) — \(browserURL)") }
        if !focusedRole.isEmpty { lines.append("Focused: \(focusedRole)\(focusedValue.isEmpty ? "" : " “\(focusedValue.prefix(120))”")") }
        if !selectedText.isEmpty { lines.append("Selected text: “\(selectedText.prefix(400))”") }
        if !elements.isEmpty {
            lines.append("Clickable/visible items:")
            for e in elements.prefix(maxElements) { lines.append("- [\(e.role)] \(e.label.prefix(80))") }
        }
        if !ocrText.isEmpty { lines.append("Text on screen (OCR):\n\(ocrText.prefix(1800))") }
        return lines.joined(separator: "\n")
    }
}

/// Reads and drives other apps' UI through the macOS Accessibility API.
public enum AX {
    public static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let posValue = value(element, kAXPositionAttribute), let sizeValue = value(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        return CGRect(origin: point, size: size)
    }

    public static func frontmostApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    static func appElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.8)
        return element
    }

    /// Chromium and Electron apps only build their web accessibility tree when asked.
    public static func enableWebAccessibility(_ app: NSRunningApplication) {
        let element = appElement(app)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    public static func focusedWindow(_ app: NSRunningApplication) -> AXUIElement? {
        guard let window = value(appElement(app), kAXFocusedWindowAttribute) else { return nil }
        return (window as! AXUIElement) // swiftlint:disable:this force_cast
    }

    public static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        guard let focused = value(system, kAXFocusedUIElementAttribute) else { return nil }
        let text = string(focused as! AXUIElement, kAXSelectedTextAttribute) // swiftlint:disable:this force_cast
        return (text?.isEmpty ?? true) ? nil : text
    }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTab", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSlider", "AXDisclosureTriangle",
        "AXCell", "AXRow", "AXImage", "AXStaticText", "AXHeading",
    ]
    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTab", "AXDisclosureTriangle", "AXCell", "AXRow", "AXTextField", "AXSearchField", "AXComboBox", "AXTextArea",
    ]

    static func label(of element: AXUIElement) -> String {
        // Editable text reports a generic description ("note body"); its value is what's actually there.
        let role = string(element, kAXRoleAttribute) ?? ""
        if ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox", "AXStaticText"].contains(role),
           let text = string(element, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, "AXValueDescription", kAXValueAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute] {
            if let text = string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        if let titleElement = value(element, kAXTitleUIElementAttribute) {
            return string(titleElement as! AXUIElement, kAXValueAttribute) ?? "" // swiftlint:disable:this force_cast
        }
        return ""
    }

    /// Breadth-first walk of the focused window, collecting labelled, visible elements.
    static func walk(_ root: AXUIElement, limit: Int = 2500, collect: (AXUIElement, String, String, CGRect) -> Bool) {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let element = queue.removeFirst()
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if interactiveRoles.contains(role), let rect = frame(element), rect.width > 1, rect.height > 1 {
                let text = label(of: element)
                if !text.isEmpty, !collect(element, role, text, rect) { return }
            }
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
    }

    @MainActor
    public static func snapshot(browser: Browser? = nil) -> ScreenSnapshot {
        var snap = ScreenSnapshot()
        guard let app = frontmostApp() else { return snap }
        snap.appName = app.localizedName ?? ""
        if Browser.chromium.contains(snap.appName) || app.bundleURL.map(isElectron) == true { enableWebAccessibility(app) }
        if let browser, Browser.all.contains(snap.appName), let tab = try? browser.currentTab() {
            snap.browserURL = tab.url
            snap.browserTitle = tab.title
        }
        snap.selectedText = selectedText() ?? ""
        let system = AXUIElementCreateSystemWide()
        if let focused = value(system, kAXFocusedUIElementAttribute) {
            let element = focused as! AXUIElement // swiftlint:disable:this force_cast
            snap.focusedRole = (string(element, kAXRoleDescriptionAttribute) ?? string(element, kAXRoleAttribute) ?? "")
            snap.focusedValue = string(element, kAXValueAttribute) ?? ""
        }
        guard let window = focusedWindow(app) else { return snap }
        snap.windowTitle = string(window, kAXTitleAttribute) ?? ""
        var seen = Set<String>()
        walk(window) { _, role, text, _ in
            let short = role.replacingOccurrences(of: "AX", with: "").lowercased()
            let key = short + text
            if seen.insert(key).inserted { snap.elements.append(UIElementInfo(role: short, label: text, frame: .zero)) }
            return snap.elements.count < 160
        }
        return snap
    }

    static func isElectron(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    /// Finds the best element matching a spoken label in the frontmost window and presses it.
    @MainActor
    public static func click(label target: String, allowMouse: Bool = true) -> Bool {
        guard let hit = find(label: target) else { return false }
        // Fields: focus them so typing lands there. Buttons and links: press.
        if editableRoles.contains(string(hit.element, kAXRoleAttribute) ?? ""),
           AXUIElementSetAttributeValue(hit.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        if AXUIElementPerformAction(hit.element, kAXPressAction as CFString) == .success { return true }
        guard allowMouse, let frame = scrollIntoView(hit.element) ?? (onScreen(hit.frame) ? hit.frame : nil) else { return false }
        Keyboard.click(at: CGPoint(x: frame.midX, y: frame.midY))
        return true
    }

    /// The best match for a visible label in the front app (focused window first).
    public static func find(label target: String) -> (element: AXUIElement, frame: CGRect)? {
        guard let app = frontmostApp() else { return nil }
        if Browser.chromium.contains(app.localizedName ?? "") || app.bundleURL.map(isElectron) == true { enableWebAccessibility(app) }
        let wanted = target.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        var best: (element: AXUIElement, score: Int, frame: CGRect)?
        let roots = [focusedWindow(app)].compactMap { $0 } + [appElement(app)]
        for root in roots {
            walk(root, limit: 3000) { element, role, text, rect in
                // Ties go to what's actually on screen, not something scrolled away behind a dialog.
                let score = matchScore(text.lowercased(), wanted) + (clickableRoles.contains(role) ? 15 : 0) + (onScreen(rect) ? 3 : 0)
                if score > 40, score > (best?.score ?? 0) { best = (element, score, rect) }
                return (best?.score ?? 0) < 118
            }
            if best != nil { break }
        }
        return best.map { ($0.element, $0.frame) }
    }

    /// Scrolls an element into view (inside dialogs and lists too) and returns its new frame when it's on screen.
    static func scrollIntoView(_ element: AXUIElement) -> CGRect? {
        if let rect = frame(element), onScreen(rect) { return rect }
        AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
        usleep(250_000)
        return frame(element).flatMap { onScreen($0) ? $0 : nil }
    }

    static func onScreen(_ rect: CGRect) -> Bool {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.contains { screen in
            let f = screen.frame
            return CGRect(x: f.minX, y: height - f.maxY, width: f.width, height: f.height).contains(CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    static func runningApp(named name: String?) -> NSRunningApplication? {
        guard let name, !name.isEmpty else { return frontmostApp() }
        let target = AppCatalog.shared.resolve(name)?.name.lowercased() ?? name.lowercased()
        return NSWorkspace.shared.runningApplications.first { $0.localizedName?.lowercased() == target }
    }

    static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        if Browser.chromium.contains(app.localizedName ?? "") || app.bundleURL.map(isElectron) == true { enableWebAccessibility(app) }
        return value(appElement(app), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    /// Text inside `region` of an app (frontmost app when `appName` is nil). Works on background windows.
    public static func text(app appName: String?, region: CGRect?, limit: Int = 1200) -> String {
        guard let app = runningApp(named: appName) else { return "" }
        var parts: [String] = []
        for window in windows(of: app).prefix(4) {
            if let region, let frame = frame(window), !frame.intersects(region) { continue }
            walk(window, limit: limit) { _, _, text, rect in
                if region == nil || rect.intersects(region!) { parts.append(text) }
                return parts.count < 800
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Presses the element labelled `label` inside `region` of an app, without bringing it forward.
    @MainActor
    public static func click(label target: String, app appName: String?, region: CGRect?) -> Bool {
        guard let app = runningApp(named: appName) else { return false }
        let wanted = target.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        var best: (element: AXUIElement, score: Int, frame: CGRect)?
        for window in windows(of: app).prefix(4) {
            if let region, let frame = frame(window), !frame.intersects(region) { continue }
            walk(window, limit: 4000) { element, role, text, rect in
                guard region == nil || rect.intersects(region!), clickableRoles.contains(role) else { return true }
                let score = matchScore(text.lowercased(), wanted)
                if score >= 65, score > (best?.score ?? 0) { best = (element, score, rect) }
                return (best?.score ?? 0) < 100
            }
        }
        guard let hit = best else { return false }
        if AXUIElementPerformAction(hit.element, kAXPressAction as CFString) == .success { return true }
        // A mouse click only lands safely when nothing could be covering the target.
        guard app.processIdentifier == frontmostApp()?.processIdentifier else {
            Log.info("Skipped clicking “\(target)”: \(app.localizedName ?? "app") isn't in front")
            return false
        }
        Keyboard.click(at: CGPoint(x: hit.frame.midX, y: hit.frame.midY))
        return true
    }

    /// All visible text in an app's windows, frontmost or not. Empty if the app isn't running.
    public static func windowText(appName: String, limit: Int = 1200) -> String {
        let target = AppCatalog.shared.resolve(appName)?.name.lowercased() ?? appName.lowercased()
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == target }) else { return "" }
        let element = appElement(app)
        let windows = value(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var parts: [String] = []
        for window in windows.prefix(4) {
            walk(window, limit: limit) { _, _, text, _ in
                parts.append(text)
                return parts.count < 600
            }
        }
        return parts.joined(separator: "\n")
    }

    static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]

    /// Types by inserting text through Accessibility — no keystrokes, so it works while ⌥⌘ is still held.
    /// If nothing editable has focus, it focuses the window's main text area (e.g. the Notes body) first.
    @MainActor
    public static func insertText(_ text: String) -> Bool {
        guard let app = frontmostApp() else { return false }
        if Browser.chromium.contains(app.localizedName ?? "") || app.bundleURL.map(isElectron) == true { enableWebAccessibility(app) }
        let element = appElement(app)
        var target: AXUIElement?
        if let focused = value(element, kAXFocusedUIElementAttribute) {
            let candidate = focused as! AXUIElement // swiftlint:disable:this force_cast
            if editableRoles.contains(string(candidate, kAXRoleAttribute) ?? "") { target = candidate }
        }
        if target == nil, let window = focusedWindow(app) {
            var largest: (AXUIElement, CGFloat)?
            walk(window, limit: 2500) { el, role, _, rect in
                if role == "AXTextArea", rect.width * rect.height > (largest?.1 ?? 0) { largest = (el, rect.width * rect.height) }
                return true
            }
            // walk() skips unlabeled elements, so also look for an empty text area directly.
            if largest == nil { largest = firstTextArea(in: window).map { ($0, 1) } }
            if let (area, _) = largest {
                AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if let length = (string(area, kAXValueAttribute))?.utf16.count {
                    var range = CFRange(location: length, length: 0)
                    if let rangeValue = AXValueCreate(.cfRange, &range) {
                        AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, rangeValue)
                    }
                }
                target = area
            }
        }
        guard let target else { return false }
        let text = spaced(text, before: characterBeforeCaret(in: target))
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(target, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        let before = string(target, kAXValueAttribute)
        guard AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        // Some apps accept the call but ignore it; only trust it if the text actually changed.
        if let before, let after = string(target, kAXValueAttribute) { return after != before }
        return true
    }

    /// Keeps inserted text from gluing onto what's already there.
    static func spaced(_ text: String, before: Character?) -> String {
        guard let before, !before.isWhitespace, let first = text.first, !first.isWhitespace,
              !",.!?;:)".contains(first) else { return text }
        return " " + text
    }

    static func characterBeforeCaret(in element: AXUIElement) -> Character? {
        guard let value = string(element, kAXValueAttribute), !value.isEmpty,
              let rangeRef = self.value(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) // swiftlint:disable:this force_cast
        let utf16 = Array(value.utf16)
        guard range.location > 0, range.location <= utf16.count else { return nil }
        return String(utf16CodeUnits: [utf16[range.location - 1]], count: 1).first
    }

    /// All readable text of the front window (web pages included), in reading order — no JavaScript needed.
    @MainActor
    public static func readableText(limit: Int = 8000) -> String {
        guard let app = frontmostApp(), let window = focusedWindow(app) else { return "" }
        if Browser.chromium.contains(app.localizedName ?? "") || app.bundleURL.map(isElectron) == true { enableWebAccessibility(app) }
        var pieces: [String] = []
        var total = 0
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 15_000, total < limit {
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if ["AXStaticText", "AXHeading", "AXTextArea", "AXTextField"].contains(role),
               let text = (string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute))?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, pieces.last != text {
                pieces.append(text)
                total += text.count + 1
            }
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { stack.append(contentsOf: children.reversed()) }
        }
        return String(pieces.joined(separator: "\n").prefix(limit))
    }

    /// The front window's search box: a real search field, or a text field labelled "Search …".
    @MainActor
    /// In a browser only the page counts: the address bar is also a "search" field, but typing there is a Google search.
    public static func focusSearchField() -> Bool {
        guard let app = frontmostApp(), let window = focusedWindow(app) else { return false }
        if Browser.chromium.contains(app.localizedName ?? "") || app.bundleURL.map(isElectron) == true { enableWebAccessibility(app) }
        var root = window
        if Browser.all.contains(app.localizedName ?? "") {
            guard let page = firstElement(role: "AXWebArea", in: window) else { return false }
            root = page
        }
        var field: AXUIElement?
        var fallback: AXUIElement?
        walk(root, limit: 4000) { element, role, text, _ in
            if role == "AXSearchField" { field = element; return false }
            if ["AXTextField", "AXComboBox"].contains(role), fallback == nil {
                let hints = [text, string(element, kAXDescriptionAttribute) ?? "", string(element, kAXPlaceholderValueAttribute) ?? "",
                             string(element, kAXTitleAttribute) ?? ""].joined(separator: " ").lowercased()
                if hints.contains("search") { fallback = element }
            }
            return true
        }
        guard let target = field ?? fallback else { return false }
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Select what's there so the new query replaces it.
        if let current = string(target, kAXValueAttribute), !current.isEmpty {
            var range = CFRange(location: 0, length: current.utf16.count)
            if let value = AXValueCreate(.cfRange, &range) { AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, value) }
        }
        return true
    }

    static func firstElement(role wanted: String, in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 2500 {
            let element = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == wanted { return element }
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return nil
    }

    static func firstTextArea(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 2500 {
            let element = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == "AXTextArea" { return element }
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return nil
    }

    /// Search result titles are links that contain a heading (Google, Bing, DuckDuckGo, YouTube…).
    @MainActor
    public static func openSearchResult(_ n: Int) -> Bool {
        guard n >= 1, let app = frontmostApp(), let window = focusedWindow(app) else { return false }
        enableWebAccessibility(app)
        var headed: [AXUIElement] = []
        var longLinks: [AXUIElement] = []
        walk(window, limit: 6000) { element, role, text, _ in
            guard role == "AXLink" else { return true }
            let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let hasHeading = children.contains { string($0, kAXRoleAttribute) == "AXHeading" }
                || children.contains { child in
                    (value(child, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains { string($0, kAXRoleAttribute) == "AXHeading" }
                }
            if hasHeading { headed.append(element) } else if text.count > 30 { longLinks.append(element) }
            return headed.count < n
        }
        let candidates = headed.count >= n ? headed : (headed.isEmpty ? longLinks : headed)
        guard candidates.count >= n else { return false }
        let target = candidates[n - 1]
        if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success { return true }
        guard let rect = frame(target) else { return false }
        Keyboard.click(at: CGPoint(x: rect.midX, y: rect.midY))
        return true
    }

    static func matchScore(_ label: String, _ wanted: String) -> Int {
        if label == wanted { return 100 }
        if label.hasPrefix(wanted) { return 80 }
        if label.contains(wanted) { return 65 }
        if wanted.count >= 3, wanted.contains(label), label.count >= 3 { return 45 }
        let a = Set(label.split(separator: " ")), b = Set(wanted.split(separator: " "))
        let overlap = a.intersection(b).count
        return b.isEmpty ? 0 : Int(Double(overlap) / Double(b.count) * 60)
    }

    /// The frame of an app's front window (global, top-left origin); the frontmost app when `appName` is nil.
    public static func frontWindowFrame(appName: String?) -> CGRect? {
        guard let app = runningApp(named: appName) else { return nil }
        return (focusedWindow(app) ?? windows(of: app).first).flatMap { frame($0) }
    }

    public static func setWindow(_ action: WindowAction) -> Bool {
        guard let app = frontmostApp() else { return false }
        if action == .hide { return app.hide() }
        guard let window = focusedWindow(app) else { return false }
        switch action {
        case .minimize: return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        case .fullscreen:
            let current = (value(window, "AXFullScreen") as? Bool) ?? false
            return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (!current) as CFBoolean) == .success
        case .close:
            guard let button = value(window, kAXCloseButtonAttribute) else { return false }
            return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success // swiftlint:disable:this force_cast
        case .zoom:
            guard let button = value(window, kAXZoomButtonAttribute) else { return false }
            return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success // swiftlint:disable:this force_cast
        case .hide: return false
        }
    }
}
