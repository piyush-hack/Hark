import AppKit

public struct BrowserTab: Sendable {
    public let url: String
    public let title: String
}

/// Drives Chromium browsers and Safari through AppleScript; falls back to keystrokes elsewhere.
@MainActor
public final class Browser {
    nonisolated public static let chromium = ["Google Chrome", "Brave Browser", "Microsoft Edge", "Arc", "Chromium", "Vivaldi", "Opera"]
    nonisolated public static let all = chromium + ["Safari", "Firefox", "Zen Browser", "Orion"]

    public var preferred: () -> String? = { nil }
    public var keyboardGate: () async -> Void = {}
    /// The tab the last `currentTab()` saw, for decisions that can't wait on the browser.
    public private(set) var lastTab: BrowserTab?

    public init() {}

    /// The frontmost browser, else the preferred one, else the system default, else Chrome.
    public func target() -> String {
        if let front = NSWorkspace.shared.frontmostApplication?.localizedName, Self.all.contains(front) { return front }
        if let p = preferred(), AppCatalog.shared.resolveExact(p) != nil { return p }
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) {
            let name = url.deletingPathExtension().lastPathComponent
            if Self.all.contains(name) { return name }
        }
        return "Google Chrome"
    }

    var isChromium: Bool { Self.chromium.contains(target()) }

    public func activate() async throws {
        let name = target()
        guard let app = AppCatalog.shared.resolveExact(name) else { throw HarkError("\(name) isn't installed.") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: config)
        try await waitForWindow(name)
    }

    /// Up to 3 s in all, so a browser that's slow to answer can't hold things up for long.
    private func waitForWindow(_ name: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (try? await windowCount(name)) ?? 0 > 0 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func windowCount(_ name: String) async throws -> Int {
        Int(try await AppleScript.run("tell application \(AppleScript.quote(name)) to count of windows")) ?? 0
    }

    public func currentTab() async throws -> BrowserTab? {
        let name = target()
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(name) ?? "").first != nil
            || NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == name }) else { return nil }
        let script: String
        if Self.chromium.contains(name) {
            script = "tell application \(AppleScript.quote(name)) to if (count of windows) > 0 then get {URL, title} of active tab of front window"
        } else if name == "Safari" {
            script = "tell application \"Safari\" to if (count of windows) > 0 then get {URL, name} of current tab of front window"
        } else { return nil }
        let parts = try await AppleScript.run(script).components(separatedBy: "\n")
        lastTab = parts.count >= 2 ? BrowserTab(url: parts[0], title: parts[1]) : nil
        return lastTab
    }

    private func bundleID(_ name: String) -> String? {
        AppCatalog.shared.resolveExact(name).flatMap { Bundle(url: $0.url)?.bundleIdentifier }
    }

    /// Opens a URL in the current tab when it's blank, otherwise in a new tab.
    public func open(_ url: URL, forceNewTab: Bool = false, replaceCurrent: Bool = false) async throws {
        let name = target()
        try await activate()
        let blank = replaceCurrent ? true : isBlank(try? await currentTab())
        if Self.chromium.contains(name) {
            let q = AppleScript.quote(name)
            if blank && !forceNewTab {
                try await AppleScript.run("tell application \(q) to set URL of active tab of front window to \(AppleScript.quote(url.absoluteString))")
            } else {
                try await AppleScript.run("tell application \(q) to tell front window to make new tab with properties {URL:\(AppleScript.quote(url.absoluteString))}")
            }
        } else if name == "Safari" {
            if blank && !forceNewTab {
                try await AppleScript.run("tell application \"Safari\" to set URL of current tab of front window to \(AppleScript.quote(url.absoluteString))")
            } else {
                try await AppleScript.run("tell application \"Safari\" to tell front window to set current tab to (make new tab with properties {URL:\(AppleScript.quote(url.absoluteString))})")
            }
        } else if let app = AppCatalog.shared.resolveExact(name) {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
        }
        lastTab = BrowserTab(url: url.absoluteString, title: "")
    }

    private func isBlank(_ tab: BrowserTab?) -> Bool {
        guard let url = tab?.url else { return false }
        return url.isEmpty || ["chrome://newtab/", "chrome://new-tab-page/", "about:blank", "favorites://", "brave://newtab/",
                               "edge://newtab/", "arc://newtab/", "about:newtab", "about:home"].contains(url)
            || url.hasPrefix("chrome-search://") || url.hasSuffix("://newtab/")
    }

    public func perform(_ action: BrowserAction) async throws {
        let name = target()
        try await activate()
        let q = AppleScript.quote(name)
        if Self.chromium.contains(name) {
            switch action {
            case .newTab: try await AppleScript.run("tell application \(q) to tell front window to make new tab")
            case .newWindow: try await AppleScript.run("tell application \(q) to make new window")
            case .incognito: try await AppleScript.run("tell application \(q) to make new window with properties {mode:\"incognito\"}")
            case .closeTab: try await AppleScript.run("tell application \(q) to close active tab of front window")
            case .closeWindow: try await AppleScript.run("tell application \(q) to close front window")
            case .back: try await AppleScript.run("tell application \(q) to tell active tab of front window to go back")
            case .forward: try await AppleScript.run("tell application \(q) to tell active tab of front window to go forward")
            case .reload: try await AppleScript.run("tell application \(q) to tell active tab of front window to reload")
            case .nextTab:
                try await AppleScript.run("tell application \(q) to tell front window to set active tab index to ((active tab index) mod (count of tabs)) + 1")
            case .previousTab:
                try await AppleScript.run("tell application \(q) to tell front window to set active tab index to (((active tab index) - 2 + (count of tabs)) mod (count of tabs)) + 1")
            case .reopenTab: await keyboardGate(); try Keyboard.press(KeyCombo(key: "t", command: true, shift: true))
            }
            return
        }
        if name == "Safari" {
            switch action {
            case .newTab: try await AppleScript.run("tell application \"Safari\" to tell front window to set current tab to (make new tab)")
            case .newWindow: try await AppleScript.run("tell application \"Safari\" to make new document")
            case .closeTab: try await AppleScript.run("tell application \"Safari\" to close current tab of front window")
            case .closeWindow: try await AppleScript.run("tell application \"Safari\" to close front window")
            default: try await keys(for: action)
            }
            return
        }
        try await keys(for: action)
    }

    private func keys(for action: BrowserAction) async throws {
        await keyboardGate()
        let combo: KeyCombo
        switch action {
        case .newTab: combo = KeyCombo(key: "t", command: true)
        case .newWindow: combo = KeyCombo(key: "n", command: true)
        case .incognito: combo = KeyCombo(key: "n", command: true, shift: true)
        case .closeTab: combo = KeyCombo(key: "w", command: true)
        case .closeWindow: combo = KeyCombo(key: "w", command: true, shift: true)
        case .back: combo = KeyCombo(key: "[", command: true)
        case .forward: combo = KeyCombo(key: "]", command: true)
        case .reload: combo = KeyCombo(key: "r", command: true)
        case .nextTab: combo = KeyCombo(key: "]", command: true, shift: true)
        case .previousTab: combo = KeyCombo(key: "[", command: true, shift: true)
        case .reopenTab: combo = KeyCombo(key: "t", command: true, shift: true)
        }
        try Keyboard.press(combo)
    }

    /// Visible page text via JavaScript (Chromium needs View → Developer → Allow JavaScript from Apple Events).
    public func pageText(limit: Int = 4000) async -> String? {
        let name = target()
        let js = "document.body ? document.body.innerText.slice(0, \(limit)) : ''"
        if Self.chromium.contains(name) {
            return try? await AppleScript.run("tell application \(AppleScript.quote(name)) to execute active tab of front window javascript \(AppleScript.quote(js))")
        }
        if name == "Safari" {
            return try? await AppleScript.run("tell application \"Safari\" to do JavaScript \(AppleScript.quote(js)) in current tab of front window")
        }
        return nil
    }
}
