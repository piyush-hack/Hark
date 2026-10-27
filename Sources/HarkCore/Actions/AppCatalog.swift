import AppKit

public struct AppInfo: Equatable, Sendable {
    public let name: String
    public let url: URL
}

/// Finds installed apps from loosely spoken names ("chrome", "vs code", "settings").
public final class AppCatalog: @unchecked Sendable {
    public static let shared = AppCatalog()

    public private(set) var apps: [AppInfo] = []
    private var byName: [String: AppInfo] = [:]
    private let lock = NSLock()

    static let aliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "chrome browser": "Google Chrome",
        "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "visual studio": "Visual Studio Code",
        "code": "Visual Studio Code", "settings": "System Settings", "system preferences": "System Settings",
        "preferences": "System Settings", "mac settings": "System Settings", "iterm": "iTerm",
        "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook", "teams": "Microsoft Teams", "brave": "Brave Browser",
        "edge": "Microsoft Edge", "text edit": "TextEdit", "quicktime": "QuickTime Player",
        "zoom": "zoom.us", "app store": "App Store", "whatsapp": "WhatsApp", "facetime": "FaceTime",
        "calculator": "Calculator", "files": "Finder", "photo booth": "Photo Booth", "simulator": "Simulator",
        "android studio": "Android Studio", "activity monitor": "Activity Monitor", "terminal app": "Terminal",
    ]

    public init(scan: Bool = true) {
        if scan { refresh() }
    }

    public init(apps: [AppInfo]) {
        load(apps)
    }

    public func refresh() {
        let fm = FileManager.default
        var roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", "/Applications/Setapp"]
        roots.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path)
        var found: [AppInfo] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                found.append(AppInfo(name: String(item.dropLast(4)), url: URL(fileURLWithPath: root).appendingPathComponent(item)))
            }
        }
        found.append(AppInfo(name: "Finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")))
        load(found)
    }

    private func load(_ found: [AppInfo]) {
        lock.lock(); defer { lock.unlock() }
        apps = found
        byName = Dictionary(found.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Exact matches only: app names and known aliases.
    public func resolveExact(_ spoken: String) -> AppInfo? {
        let key = Self.normalize(spoken)
        guard !key.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let alias = Self.aliases[key], let app = byName[alias.lowercased()] { return app }
        if let app = byName[key] { return app }
        let squashed = key.replacingOccurrences(of: " ", with: "")
        return apps.first { $0.name.lowercased().replacingOccurrences(of: " ", with: "") == squashed }
    }

    /// Exact match, then prefix, then a small edit distance for mis-heard names.
    public func resolve(_ spoken: String) -> AppInfo? {
        if let exact = resolveExact(spoken) { return exact }
        let key = Self.normalize(spoken)
        guard key.count >= 3 else { return nil }
        lock.lock(); defer { lock.unlock() }
        let prefixed = apps.filter { $0.name.lowercased().hasPrefix(key + " ") || $0.name.lowercased() == key }
        if prefixed.count == 1 { return prefixed[0] }
        let wordMatch = apps.filter { $0.name.lowercased().split(separator: " ").contains { $0 == key } }
        if wordMatch.count == 1 { return wordMatch[0] }
        let budget = key.count >= 7 ? 2 : (key.count >= 4 ? 1 : 0)
        guard budget > 0 else { return nil }
        // Mis-heard names: compare against aliases, full names, and single words of names.
        if let alias = Self.aliases.first(where: { Self.distance($0.key, key) <= budget }),
           let app = byName[alias.value.lowercased()] { return app }
        let scored = apps.map { app -> (AppInfo, Int) in
            let name = app.name.lowercased()
            let wordBest = name.split(separator: " ").filter { $0.count >= 4 }.map { Self.distance(String($0), key) }.min() ?? Int.max
            return (app, min(Self.distance(name, key), wordBest))
        }.filter { $0.1 <= budget }
        let best = scored.map(\.1).min()
        let winners = scored.filter { $0.1 == best }
        if winners.count == 1 { return winners[0].0 }
        return soundAlike(key)
    }

    /// "groom" → Chrome, "spot a fly" → Spotify: compare how names sound, not how they're spelled.
    private func soundAlike(_ spoken: String) -> AppInfo? {
        let key = Vocabulary.soundKey(spoken)
        guard key.count >= 3 else { return nil }
        var hits: [AppInfo] = []
        for (alias, name) in Self.aliases where Vocabulary.soundKey(alias) == key {
            if let app = byName[name.lowercased()], !hits.contains(app) { hits.append(app) }
        }
        for app in apps where Vocabulary.soundKey(app.name) == key || app.name.split(separator: " ").contains(where: { Vocabulary.soundKey(String($0)) == key && $0.count >= 4 }) {
            if !hits.contains(app) { hits.append(app) }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    public func runningApplication(named name: String) -> NSRunningApplication? {
        let target = resolve(name)?.name.lowercased() ?? Self.normalize(name)
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased() == target || $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == target
        }
    }

    static func normalize(_ text: String) -> String {
        var s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for prefix in ["the ", "my ", "up "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        for suffix in [" app", " application", " for me", " please"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
