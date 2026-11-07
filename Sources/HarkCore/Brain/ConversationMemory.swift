import Foundation

/// The Claude Code conversation Hark is in the middle of, kept on disk so a stopped process, an error, or a relaunched
/// Hark carries on with it (`--resume`). It lasts until nothing has happened for `idle` seconds; then the next request
/// starts a new one.
public struct ConversationMemory: @unchecked Sendable {
    private let key: String
    private let idle: TimeInterval
    private let defaults: UserDefaults

    public init(key: String, idle: TimeInterval, defaults: UserDefaults = .standard) {
        self.key = key
        self.idle = idle
        self.defaults = defaults
    }

    /// The conversation to carry on, if it's still going.
    public func current(at now: Date = Date()) -> String? {
        guard let id = defaults.string(forKey: key), let used = defaults.object(forKey: key + "Used") as? Date,
              now.timeIntervalSince(used) < idle else { return nil }
        return id
    }

    /// Claude was just active in this conversation.
    public func save(_ id: String, at now: Date = Date()) {
        defaults.set(id, forKey: key)
        defaults.set(now, forKey: key + "Used")
    }

    public func forget() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: key + "Used")
    }
}
