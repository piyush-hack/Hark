import Foundation

/// A how-to Hark learned by doing: written by Claude after a task it verified on screen, so the next similar request
/// goes straight to what works instead of exploring again.
public struct Lesson: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    /// General task, no specifics: "delete a note in Notes".
    public var task: String
    /// What worked (and what didn't), generalized.
    public var how: String
    public var app: String
    /// Website host for browser tasks ("linkedin.com"); empty otherwise.
    public var site: String
    public var successes: Int
    public var failures: Int
    public var created: Date
    public var lastUsed: Date
}

/// Hark's memory of how to do things here. Stored on this Mac only (lessons.json).
@MainActor
public final class LessonBook: ObservableObject {
    @Published public private(set) var lessons: [Lesson] = []
    private let file: URL?
    /// Few and useful: past this, the least-used are dropped.
    static let limit = 40

    public init(file: URL? = Paths.appSupport.appendingPathComponent("lessons.json")) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Lesson].self, from: data) { lessons = saved }
    }

    // MARK: Finding

    /// The few lessons most likely to help with `request`: same app or site first, then shared words.
    public func relevant(to request: String, app: String, site: String, limit: Int = 3) -> [Lesson] {
        let wanted = Self.keywords(request)
        let scored = lessons.compactMap { lesson -> (Lesson, Double)? in
            guard lesson.failures < 2 else { return nil }
            let overlap = Double(wanted.intersection(Self.keywords(lesson.task + " " + lesson.app)).count)
            guard overlap > 0 else { return nil }
            var score = overlap / Double(max(1, Self.keywords(lesson.task).count)).squareRoot()
            if !lesson.app.isEmpty, lesson.app.caseInsensitiveCompare(app) == .orderedSame
                || request.lowercased().contains(lesson.app.lowercased()) { score += 1.5 }
            if !lesson.site.isEmpty, site.hasSuffix(lesson.site) { score += 1.5 }
            score += Double(lesson.successes) * 0.1
            return score >= 1.2 ? (lesson, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Words that carry meaning, roughly stemmed ("deleting notes" ~ "delete note").
    static func keywords(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "to", "in", "on", "of", "for", "and", "or", "my", "this", "that", "it", "is", "be",
                                 "with", "from", "at", "by", "me", "please", "can", "you", "i", "current", "then", "now", "just"]
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !stop.contains($0) }
        return Set(words.map { word in
            var w = word
            for suffix in ["ing", "ed", "es", "s"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) { w.removeLast(suffix.count); break }
            if w.hasSuffix("e"), w.count > 3 { w.removeLast() }
            return w
        })
    }

    // MARK: Learning

    /// Saves a verified how-to; a lesson for the same task in the same place is replaced, keeping its track record.
    public func learn(task: String, how: String, app: String, site: String) {
        let task = String(task.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let how = String(how.trimmingCharacters(in: .whitespacesAndNewlines).prefix(320))
        guard !task.isEmpty, !how.isEmpty else { return }
        let words = Self.keywords(task)
        if let index = lessons.firstIndex(where: { $0.app == app && $0.site == site
            && Double(words.intersection(Self.keywords($0.task)).count) >= Double(max(words.count, Self.keywords($0.task).count)) * 0.6 }) {
            lessons[index].task = task
            lessons[index].how = how
            lessons[index].successes += 1
            lessons[index].failures = 0
            lessons[index].lastUsed = Date()
            if file != nil { Log.info("Updated what I know: \(task)") }
        } else {
            let next = (lessons.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
            lessons.append(Lesson(id: "L\(next)", task: task, how: how, app: app, site: site, successes: 1, failures: 0,
                                  created: Date(), lastUsed: Date()))
            if file != nil { Log.info("Learned: \(task) — \(how)") }
        }
        prune()
        save()
    }

    /// A lesson was followed and the result was verified.
    public func worked(_ id: String) {
        guard let index = lessons.firstIndex(where: { $0.id == id }) else { return }
        lessons[index].successes += 1
        lessons[index].failures = 0
        lessons[index].lastUsed = Date()
        save()
    }

    /// A lesson didn't work (Claude said so, or the run couldn't be verified). Two strikes and it's out.
    public func failed(_ id: String) {
        guard let index = lessons.firstIndex(where: { $0.id == id }) else { return }
        lessons[index].failures += 1
        if file != nil { Log.info("Lesson \(id) didn't work (\(lessons[index].failures)×): \(lessons[index].task)") }
        if lessons[index].failures >= 2 { lessons.remove(at: index) }
        save()
    }

    public func forget(_ id: String) {
        lessons.removeAll { $0.id == id }
        save()
    }

    public func forgetAll() {
        lessons = []
        save()
    }

    private func prune() {
        guard lessons.count > Self.limit else { return }
        lessons.sort { ($0.successes, $0.lastUsed) > ($1.successes, $1.lastUsed) }
        lessons.removeLast(lessons.count - Self.limit)
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(lessons) { try? data.write(to: file, options: .atomic) }
    }
}
