import Foundation

public enum SearchSite: String, Codable, CaseIterable, Sendable {
    case google, youtube, amazon, github, maps, wikipedia, images, news

    public func url(for query: String) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        switch self {
        case .google: return URL(string: "https://www.google.com/search?q=\(q)")!
        case .youtube: return URL(string: "https://www.youtube.com/results?search_query=\(q)")!
        case .amazon: return URL(string: "https://www.amazon.com/s?k=\(q)")!
        case .github: return URL(string: "https://github.com/search?q=\(q)")!
        case .maps: return URL(string: "https://www.google.com/maps/search/\(q)")!
        case .wikipedia: return URL(string: "https://en.wikipedia.org/w/index.php?search=\(q)")!
        case .images: return URL(string: "https://www.google.com/search?tbm=isch&q=\(q)")!
        case .news: return URL(string: "https://news.google.com/search?q=\(q)")!
        }
    }

    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .youtube: return "YouTube"
        case .amazon: return "Amazon"
        case .github: return "GitHub"
        case .maps: return "Maps"
        case .wikipedia: return "Wikipedia"
        case .images: return "Google Images"
        case .news: return "Google News"
        }
    }
}

public enum BrowserAction: String, Codable, CaseIterable, Sendable {
    case newTab = "new_tab", newWindow = "new_window", incognito, closeTab = "close_tab", closeWindow = "close_window"
    case back, forward, reload, nextTab = "next_tab", previousTab = "previous_tab", reopenTab = "reopen_tab"
}

public enum ScrollDirection: String, Codable, Sendable { case up, down, top, bottom, left, right }
public enum ScrollAmount: String, Codable, Sendable { case small, medium, large }

public enum SystemAction: String, Codable, CaseIterable, Sendable {
    case volumeUp = "volume_up", volumeDown = "volume_down", mute, unmute, setVolume = "set_volume"
    case playPause = "play_pause", play, pause, nextTrack = "next_track", previousTrack = "previous_track"
    case lockScreen = "lock_screen", sleepDisplay = "sleep_display", darkModeOn = "dark_mode_on"
    case darkModeOff = "dark_mode_off", toggleDarkMode = "toggle_dark_mode", screenshot
    case brightnessUp = "brightness_up", brightnessDown = "brightness_down", showDesktop = "show_desktop"
    case missionControl = "mission_control"
}

public enum WindowAction: String, Codable, Sendable { case minimize, fullscreen, close, hide, zoom }

public struct KeyCombo: Equatable, Codable, Sendable, CustomStringConvertible {
    public var key: String
    public var command = false, option = false, control = false, shift = false

    public init(key: String, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.key = key; self.command = command; self.option = option; self.control = control; self.shift = shift
    }

    /// Parses "cmd+shift+t", "command shift t", "enter", "control c".
    public init?(spoken: String) {
        let parts = spoken.lowercased()
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { !["and", "the", "key", "keys", "button"].contains($0) }
        guard !parts.isEmpty else { return nil }
        var combo = KeyCombo(key: "")
        for part in parts {
            switch part {
            case "cmd", "command", "⌘", "commands": combo.command = true
            case "option", "opt", "alt", "⌥", "options": combo.option = true
            case "control", "ctrl", "ctl", "⌃": combo.control = true
            case "shift", "⇧": combo.shift = true
            default:
                guard combo.key.isEmpty, let key = KeyCombo.normalizedKey(part) else { return nil }
                combo.key = key
            }
        }
        guard !combo.key.isEmpty else { return nil }
        self = combo
    }

    static func normalizedKey(_ word: String) -> String? {
        let aliases: [String: String] = [
            "enter": "return", "return": "return", "escape": "escape", "esc": "escape", "tab": "tab",
            "space": "space", "spacebar": "space", "delete": "delete", "backspace": "delete",
            "up": "up", "down": "down", "left": "left", "right": "right", "home": "home", "end": "end",
            "pageup": "pageup", "pagedown": "pagedown", "comma": ",", "period": ".", "dot": ".", "slash": "/",
            "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
            "six": "6", "seven": "7", "eight": "8", "nine": "9",
        ]
        if let alias = aliases[word] { return alias }
        if word.count == 1 { return word }
        if word.hasPrefix("f"), let n = Int(word.dropFirst()), (1...12).contains(n) { return word }
        return nil
    }

    public var description: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        let symbols = ["return": "↩", "escape": "⎋", "tab": "⇥", "space": "Space", "delete": "⌫",
                       "up": "↑", "down": "↓", "left": "←", "right": "→"]
        return s + (symbols[key] ?? key.uppercased())
    }
}

public enum Command: Equatable, Sendable {
    case openApp(String)
    case quitApp(String)
    case openURL(URL)
    case webSearch(String, SearchSite)
    /// "search for X" with no site named: the current app's / page's own search, Google only as a fallback.
    case searchHere(String)
    case searchSelection(SearchSite)
    /// Re-runs a search in the same tab with a longer query (continuation after a pause).
    case refineSearch(String, SearchSite)
    case browser(BrowserAction)
    case typeText(String)
    case pressKeys(KeyCombo)
    case scroll(ScrollDirection, ScrollAmount)
    case click(String)
    case system(SystemAction, Int?)
    case window(WindowAction)
    case wait(TimeInterval)
    case tellTime
    case tellDate
    /// Run `task` later. Reminders are spoken; other tasks are executed like a fresh voice command.
    case schedule(after: TimeInterval?, at: DateComponents?, task: String, reminder: Bool)
    /// "every day at 9am, open Gmail" — `when` is understood by `Scheduler.trigger(from:)`.
    case recurring(when: String, task: String)
    case claude(String)
    case downloadCurrent
    /// Open the Nth link in a page of search results (1-based).
    case openResult(Int)
    /// Speak a canned answer without waking the model.
    case say(String)
    /// Watch the screen / an app and act when it changes or text appears.
    case watch(WatchSpec)
    case stopWatching
    /// "close it / close this": the current tab in a browser, otherwise the front window.
    case closeCurrent
    case stop
    case agent(String)

    /// True when the command synthesizes keystrokes and must wait until the hotkey is released.
    public var needsKeyboard: Bool {
        switch self {
        case .typeText, .pressKeys, .click, .claude, .searchSelection: return true
        case .window(let action): return action != .hide
        case .browser(let action): return action == .reopenTab
        case .system(let action, _): return action == .screenshot || action == .missionControl || action == .showDesktop
        default: return false
        }
    }

    /// True when the command takes free text that a mid-sentence pause could cut short.
    public var isOpenEnded: Bool {
        switch self {
        case .webSearch, .searchHere, .click, .schedule, .recurring, .claude, .agent, .openURL, .watch: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .openApp(let name): return "Open \(name)"
        case .quitApp(let name): return "Quit \(name)"
        case .openURL(let url): return "Open \(url.host ?? url.absoluteString)"
        case .webSearch(let q, let site): return site == .google ? "Google “\(q)”" : "Search \(site.displayName) for “\(q)”"
        case .searchHere(let q): return "Search “\(q)”"
        case .searchSelection(let site): return "Search \(site.displayName) for selection"
        case .refineSearch(let q, _): return "Search “\(q)”"
        case .browser(let a):
            switch a {
            case .newTab: return "New tab"
            case .newWindow: return "New window"
            case .incognito: return "New incognito window"
            case .closeTab: return "Close tab"
            case .closeWindow: return "Close window"
            case .back: return "Go back"
            case .forward: return "Go forward"
            case .reload: return "Reload page"
            case .nextTab: return "Next tab"
            case .previousTab: return "Previous tab"
            case .reopenTab: return "Reopen closed tab"
            }
        case .typeText(let t): return "Type “\(t.count > 40 ? String(t.prefix(40)) + "…" : t)”"
        case .pressKeys(let k): return "Press \(k)"
        case .scroll(let d, _): return "Scroll \(d.rawValue)"
        case .click(let t): return "Click “\(t)”"
        case .system(let a, let v):
            switch a {
            case .setVolume: return "Volume \(v ?? 50)%"
            case .volumeUp: return "Volume up"
            case .volumeDown: return "Volume down"
            case .mute: return "Mute"
            case .unmute: return "Unmute"
            case .playPause: return "Play / pause"
            case .play: return "Play"
            case .pause: return "Pause"
            case .nextTrack: return "Next track"
            case .previousTrack: return "Previous track"
            case .lockScreen: return "Lock screen"
            case .sleepDisplay: return "Sleep display"
            case .darkModeOn: return "Dark mode on"
            case .darkModeOff: return "Dark mode off"
            case .toggleDarkMode: return "Toggle dark mode"
            case .screenshot: return "Screenshot"
            case .brightnessUp: return "Brightness up"
            case .brightnessDown: return "Brightness down"
            case .showDesktop: return "Show desktop"
            case .missionControl: return "Mission Control"
            }
        case .window(let a): return "\(a.rawValue.capitalized) window"
        case .wait(let s): return "Wait \(Int(s))s"
        case .tellTime: return "Tell the time"
        case .tellDate: return "Tell the date"
        case .schedule(_, _, let task, let reminder): return reminder ? "Reminder: \(task)" : "Scheduled: \(task)"
        case .recurring(let when, let task): return "\(when.prefix(1).uppercased() + when.dropFirst()): \(task)"
        case .claude(let p): return "Claude Code: “\(p.count > 40 ? String(p.prefix(40)) + "…" : p)”"
        case .downloadCurrent: return "Download this"
        case .openResult(let n): return "Open result \(n)"
        case .say(let text): return text
        case .watch(let spec):
            let place: String
            switch spec.scope {
            case .here: place = "this area"
            case .app(let app): place = app
            case .anywhere: place = "any app"
            }
            return spec.text.map { "Watch \(place) for “\($0)”" } ?? "Watch \(place)"
        case .stopWatching: return "Stop watching"
        case .closeCurrent: return "Close it"
        case .stop: return "Stop"
        case .agent(let t): return t
        }
    }

    /// Short phrase spoken in "brief" mode.
    public var spoken: String? {
        switch self {
        case .openApp(let name): return "Opening \(name)"
        case .quitApp(let name): return "Quitting \(name)"
        case .openURL(let url): return "Opening \(url.host?.replacingOccurrences(of: "www.", with: "") ?? "the link")"
        case .webSearch(let q, let site): return site == .google ? "Searching for \(q)" : "Searching \(site.displayName) for \(q)"
        case .searchHere(let q): return "Searching for \(q)"
        case .schedule, .recurring: return nil
        case .claude: return "Sent to Claude"
        case .downloadCurrent: return "Downloading"
        case .openResult(let n): return n == 1 ? "Opening the first result" : "Opening result \(n)"
        case .say, .watch, .stopWatching: return nil
        case .system(.lockScreen, _), .tellTime, .tellDate, .stop, .wait, .agent: return nil
        default: return title
        }
    }
}
