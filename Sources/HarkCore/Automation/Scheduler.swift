import AppKit
import Combine

public struct Automation: Codable, Identifiable, Equatable, Sendable {
    public enum Trigger: Codable, Equatable, Sendable {
        case once(Date)
        case daily(hour: Int, minute: Int)
        case every(TimeInterval)
        case newFile(folder: String)
        case appLaunch(String)
        /// Fires when `text` shows up in an app's windows (checked every few seconds, no model involved).
        case textAppears(app: String, text: String)
        /// Fires when a region / app changes, or when text appears in it.
        case screenWatch(ScreenWatch)
    }

    public var id = UUID()
    public var trigger: Trigger
    /// For reminders, the words to say; otherwise an instruction run like a voice command.
    public var task: String
    public var reminder: Bool
    public var createdBy: String
    public var createdAt = Date()
    public var lastRun: Date?

    public init(trigger: Trigger, task: String, reminder: Bool, createdBy: String) {
        self.trigger = trigger; self.task = task; self.reminder = reminder; self.createdBy = createdBy
    }

    public func nextRun(after now: Date = Date()) -> Date? {
        switch trigger {
        case .once(let date): return lastRun == nil ? date : nil
        case .every(let interval): return (lastRun ?? createdAt).addingTimeInterval(max(interval, 30))
        case .daily(let hour, let minute):
            return Calendar.current.nextDate(after: lastRun.map { max($0, now.addingTimeInterval(-1)) } ?? now.addingTimeInterval(-1),
                                             matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
        case .newFile, .appLaunch, .textAppears, .screenWatch: return nil
        }
    }

    public var summary: String {
        let when: String
        switch trigger {
        case .once(let date):
            let f = DateFormatter()
            f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
            f.timeStyle = .short
            when = "at \(f.string(from: date))"
        case .daily(let h, let m): when = String(format: "every day at %02d:%02d", h, m)
        case .every(let s): when = s >= 3600 ? "every \(Int(s / 3600))h" : "every \(Int(s / 60)) min"
        case .newFile(let folder): when = "when a file lands in \((folder as NSString).lastPathComponent)"
        case .appLaunch(let app): when = "when \(app) opens"
        case .textAppears(let app, let text): when = "when “\(text)” appears in \(app)"
        case .screenWatch(let watch): when = "when \(watch.label)"
        }
        return (reminder ? "Remind: " : "") + task + " — " + when
    }
}

/// Runs automations on time, file, and app events. The language model is only woken when one fires.
@MainActor
public final class Scheduler: ObservableObject {
    @Published public private(set) var automations: [Automation] = []
    public var onFire: ((Automation, String?) -> Void)?

    private var timer: Timer?
    private var folderSources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var knownFiles: [UUID: Set<String>] = [:]
    private var launchObserver: NSObjectProtocol?

    public init() {
        load()
    }

    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let name = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? ""
            MainActor.assumeIsolated { self?.appLaunched(name) }
        }
        rebuildWatchers()
    }

    @discardableResult
    public func add(_ automation: Automation) -> Automation {
        // Asking twice for the same thing shouldn't make it happen twice.
        if let existing = automations.first(where: { $0.trigger == automation.trigger && $0.task.lowercased() == automation.task.lowercased() && $0.reminder == automation.reminder }),
           !isOneShot(automation.trigger) {
            return existing
        }
        automations.append(automation)
        save()
        rebuildWatchers()
        return automation
    }

    public func remove(_ id: UUID) {
        automations.removeAll { $0.id == id }
        save()
        rebuildWatchers()
    }

    private var tickCount = 0
    private var textSeen: [UUID: Int] = [:]

    private struct WatchState {
        var counts: [String: Int] = [:]
        var fingerprint: [UInt8]?
        var signature: Int?
        var lastFire = Date.distantPast
        var busy = false
    }
    private var watchState: [UUID: WatchState] = [:]

    private func tick() {
        tickCount += 1
        if tickCount % 15 == 0 { checkTextWatchers() }
        checkScreenWatchers()
        let now = Date()
        for automation in automations {
            guard let due = automation.nextRun(after: now), due <= now else { continue }
            fire(automation.id, context: nil)
        }
    }

    private func fire(_ id: UUID, context: String?) {
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[index].lastRun = Date()
        let automation = automations[index]
        if case .once = automation.trigger { automations.remove(at: index) }
        // Event watchers can fire often; only time-based ones need their last run on disk.
        switch automation.trigger {
        case .once, .daily, .every: save()
        default: break
        }
        Log.info("Automation fired: \(automation.summary)")
        onFire?(automation, context)
    }

    private func checkTextWatchers() {
        for automation in automations {
            guard case .textAppears(let app, let text) = automation.trigger else { continue }
            let id = automation.id
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let count = AX.windowText(appName: app).lowercased().components(separatedBy: text.lowercased()).count - 1
                DispatchQueue.main.async { [weak self] in self?.textCounted(id, app: app, text: text, count: count) }
            }
        }
    }

    /// Count matches so a new "hello" fires even when an older one is already on screen.
    private func textCounted(_ id: UUID, app: String, text: String, count: Int) {
        let before = textSeen[id]
        textSeen[id] = count
        if let before, count > before {
            fire(id, context: "“\(text)” just appeared in \(app).")
        }
    }

    /// About once a second: text via Accessibility, visual change via a 32×32 thumbnail. No model involved.
    private func checkScreenWatchers() {
        for automation in automations {
            guard case .screenWatch(let watch) = automation.trigger else { continue }
            let id = automation.id
            var state = watchState[id] ?? WatchState()
            guard !state.busy else { continue }
            if let text = watch.text {
                // Reading another app's UI isn't free: front app every 3 s, background apps every 15 s.
                let front = NSWorkspace.shared.frontmostApplication?.localizedName
                let interval = (watch.app == nil || watch.app == front) ? 3 : 15
                guard tickCount % interval == 0 else { continue }
                // Per-app counts, so switching apps in "anywhere" mode doesn't look like new text.
                let appKey = watch.app ?? front ?? "?"
                state.busy = true
                watchState[id] = state
                // Reading another app's UI can take a while; never do it on the main thread.
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let body = AX.text(app: watch.app, region: watch.rect).lowercased()
                    let axCount = body.components(separatedBy: text.lowercased()).count - 1
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        var count = axCount
                        var source = "\(body.count) chars of accessibility text"
                        // Web views and terminals (Claude Code's panel, for one) hide their text from Accessibility:
                        // read what's actually on screen — only while that app is in front, so it's really its pixels.
                        // In front: read the screen there. Behind other windows: capture that app's window itself.
                        let appInFront = watch.app == nil || watch.app == NSWorkspace.shared.frontmostApplication?.localizedName
                        if count == 0, ScreenText.hasPermission, let area = watch.rect ?? AX.frontWindowFrame(appName: watch.app) {
                            var lines: [OCRLine]?
                            if appInFront {
                                lines = try? await ScreenText.recognize(in: area)
                            } else if let app = AX.runningApp(named: watch.app), watch.app != nil {
                                lines = try? await ScreenText.recognize(app: app.processIdentifier, area: area)
                            }
                            if let lines {
                                let seen = lines.map(\.text).joined(separator: "\n").lowercased()
                                count = seen.components(separatedBy: text.lowercased()).count - 1
                                source = "\(lines.count) lines read from the \(appInFront ? "screen" : "window")"
                            }
                        }
                        var current = self.watchState[id] ?? WatchState()
                        current.busy = false
                        if current.counts[appKey] != count {
                            Log.info("Watch “\(text)” in \(appKey): \(count) match(es) in \(source)")
                        }
                        // A click watcher acts whenever its text is showing (a new prompt can replace the last one
                        // before the old text ever disappears); others fire when the text newly appears.
                        let clicks = self.automations.first { $0.id == id }?.task.lowercased().hasPrefix("click ") ?? false
                        if clicks ? count > 0 : (current.counts[appKey].map { count > $0 } ?? false) {
                            self.fireWatch(id, &current, context: "“\(text)” appeared in \(appKey).")
                        }
                        current.counts[appKey] = count
                        self.watchState[id] = current
                    }
                }
                continue
            } else if let rect = watch.rect, ScreenText.hasPermission {
                state.busy = true
                watchState[id] = state
                Task { @MainActor [weak self] in
                    let print = await RegionFingerprint.capture(rect)
                    guard let self else { return }
                    var current = self.watchState[id] ?? WatchState()
                    current.busy = false
                    if let print {
                        if let old = current.fingerprint, RegionFingerprint.differs(old, print) {
                            self.fireWatch(id, &current, context: "Something changed in \(watch.label.replacingOccurrences(of: " changes", with: "")).")
                        }
                        current.fingerprint = print
                    }
                    self.watchState[id] = current
                }
                continue
            } else {
                state.busy = true
                watchState[id] = state
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let signature = AX.text(app: watch.app, region: watch.rect).hashValue
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        var current = self.watchState[id] ?? WatchState()
                        current.busy = false
                        if let before = current.signature, before != signature {
                            self.fireWatch(id, &current, context: "Something changed in \(watch.app ?? "the front app").")
                        }
                        current.signature = signature
                        self.watchState[id] = current
                    }
                }
                continue
            }
            watchState[id] = state
        }
    }

    private func fireWatch(_ id: UUID, _ state: inout WatchState, context: String) {
        guard Date().timeIntervalSince(state.lastFire) > 3 else { Log.info("Watcher cooling down"); return }
        Log.info("Watcher triggered: \(context)")
        state.lastFire = Date()
        fire(id, context: context)
    }

    private func appLaunched(_ name: String) {
        for automation in automations {
            if case .appLaunch(let app) = automation.trigger, app.lowercased() == name.lowercased() {
                fire(automation.id, context: "\(name) just opened.")
            }
        }
    }

    private func rebuildWatchers() {
        folderSources.values.forEach { $0.cancel() }
        folderSources.removeAll()
        for automation in automations {
            guard case .newFile(let folder) = automation.trigger else { continue }
            let path = (folder as NSString).expandingTildeInPath
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            knownFiles[automation.id] = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            let id = automation.id
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.folderChanged(id, path: path) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            folderSources[id] = source
        }
    }

    private func folderChanged(_ id: UUID, path: String) {
        let current = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
        let partial = ["crdownload", "download", "part", "tmp", "partial"]
        let added = current.subtracting(knownFiles[id] ?? []).filter { name in
            !name.hasPrefix(".") && !partial.contains((name as NSString).pathExtension.lowercased())
        }
        knownFiles[id] = current
        for name in added.sorted() {
            fire(id, context: "New file: \((path as NSString).appendingPathComponent(name))")
        }
    }

    private func isOneShot(_ trigger: Automation.Trigger) -> Bool {
        if case .once = trigger { return true }
        return false
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.automationsFile) else { return }
        let saved = (try? JSONDecoder().decode([Automation].self, from: data)) ?? []
        var unique: [Automation] = []
        for automation in saved where isOneShot(automation.trigger) || !unique.contains(where: {
            $0.trigger == automation.trigger && $0.task.lowercased() == automation.task.lowercased() && $0.reminder == automation.reminder
        }) {
            unique.append(automation)
        }
        automations = unique
        if unique.count != saved.count { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(automations).write(to: Paths.automationsFile, options: .atomic)
    }

    /// Builds an automation from loose words: "in 10 minutes", "at 6pm", "every day at 9am", "every 30 minutes".
    public static func trigger(from when: String, now: Date = Date()) -> Automation.Trigger? {
        let w = when.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let m = w.firstMatch(#"^(?:every day|daily|each day|every morning|every evening) at (.+)$"#), let t = Durations.parseClock(m[1]) {
            return .daily(hour: t.hour ?? 9, minute: t.minute ?? 0)
        }
        if let m = w.firstMatch(#"^every (.+)$"#), let d = Durations.parse(m[1]) ?? Durations.parse("1 " + m[1]) { return .every(d) }
        if let m = w.firstMatch(#"^(?:in|after) (.+)$"#), let d = Durations.parse(m[1]) { return .once(now.addingTimeInterval(d)) }
        if let d = Durations.parse(w) { return .once(now.addingTimeInterval(d)) }
        let clock = w.replacingOccurrences(of: #"^(?:at|today at|tonight at)\s+"#, with: "", options: .regularExpression)
        if let tomorrow = clock.firstMatch(#"^tomorrow(?: at)? (.+)$"#), let t = Durations.parseClock(tomorrow[1]),
           let day = Calendar.current.date(byAdding: .day, value: 1, to: now) {
            return Calendar.current.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: day).map { .once($0) }
        }
        if let t = Durations.parseClock(clock) { return .once(nextOccurrence(of: t, after: now)) }
        return nil
    }

    public static func nextOccurrence(of time: DateComponents, after now: Date = Date()) -> Date {
        Calendar.current.nextDate(after: now, matching: DateComponents(hour: time.hour, minute: time.minute ?? 0, second: 0),
                                  matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
    }
}
