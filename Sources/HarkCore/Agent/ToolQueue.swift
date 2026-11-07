import Foundation

/// Hark tool calls Claude has sent and not had answered yet. Claude often sends several in one message and Claude Code
/// runs them one at a time, announcing the later ones while the first still runs, so a step can tell whether it's the
/// last: only that one needs to wait for the screen and bring it back. A later call announced too late only costs one
/// spare screenshot; the last call of a message always finds nothing queued behind it.
public final class ToolQueue: @unchecked Sendable {
    private var open: Set<String> = []
    private var message: String?
    private let lock = NSLock()

    public init() {}

    /// Reads one event from the session: a call announced, a result delivered, or the whole request over.
    public func note(_ event: [String: Any]) {
        let blocks = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        lock.lock(); defer { lock.unlock() }
        switch event["type"] as? String {
        case "assistant":
            // Claude only answers once it has every result of its last message, so nothing of that one can still be
            // running: a lost event costs one screen at most, never the rest of the run.
            if let id = (event["message"] as? [String: Any])?["id"] as? String, id != message {
                message = id
                open.removeAll()
            }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String, name.hasPrefix("mcp__hark__"), let id = block["id"] as? String else { continue }
                open.insert(id)
            }
        case "user":
            for block in blocks where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { open.remove(id) }
            }
        case "result":
            open.removeAll()
        default:
            break
        }
    }

    /// A stopped run never reports its last results; the next request starts clean.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        open.removeAll()
    }

    /// True when, besides the step running now, another is waiting its turn.
    public var moreQueued: Bool {
        lock.lock(); defer { lock.unlock() }
        return open.count > 1
    }
}
