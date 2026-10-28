import Foundation

/// How much working out one Claude run took, from its tool calls: steps that failed, steps redone (the same click or
/// the same text again, because the first try didn't do it), backing out (Escape, undo), and looking around. With
/// enough of it Hark asks Claude whether it learned something; Claude decides, and a run that was long but
/// straightforward (25 rows typed one after another) isn't a lesson.
public struct RunEffort: Sendable {
    public private(set) var actions = 0, looks = 0, failures = 0, redos = 0, backtracks = 0
    private var done: Set<String> = []

    public init() {}

    public mutating func looked() { looks += 1 }

    public mutating func failed() { failures += 1 }

    public mutating func acted(_ name: String, _ arguments: [String: String]) {
        actions += 1
        if name == "press_keys" {
            // Keys repeat naturally (↓, Tab, Return); only backing out counts.
            let keys = (arguments["keys"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            if ["escape", "esc", "cmd+z", "command+z", "cmd+[", "command+["].contains(keys) { backtracks += 1 }
            return
        }
        guard !["scroll", "wait"].contains(name) else { return }
        if name == "browser", arguments["action"]?.lowercased() == "back" { backtracks += 1 }
        let step = name + "|" + arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        if !done.insert(step).inserted { redos += 1 }
    }

    /// Something had to be worked out: a step failed, was redone or backed out of, or it took a lot of looking.
    public var worthAsking: Bool {
        failures + redos + backtracks > 0 || (looks >= 4 && actions >= 3)
    }

    /// For the log: "2 failed, 3 redone, 1 backed out, 7 looks, 12 actions".
    public var summary: String {
        [(failures, "failed"), (redos, "redone"), (backtracks, "backed out")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            .joined(separator: ", ") + (failures + redos + backtracks > 0 ? ", " : "") + "\(looks) looks, \(actions) actions"
    }
}
