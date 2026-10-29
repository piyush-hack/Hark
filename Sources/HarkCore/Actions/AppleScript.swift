import Foundation

/// In-process AppleScript, so macOS asks for Automation access on behalf of Hark itself.
/// Scripts run one at a time off the main thread: an app that is launching, busy, or waiting on a permission
/// prompt can hold its reply for minutes, and Hark must stay responsive meanwhile.
public enum AppleScript {
    /// How long a script waits for an app to answer.
    static let replyTimeout = 5
    /// A permission prompt holds the reply past the script's own timeout, so the caller stops waiting here.
    static let deadline: TimeInterval = 8
    private static let queue = DispatchQueue(label: "dev.hark.applescript", qos: .userInitiated)
    // Touched only on `queue`.
    private static var lastFailure = ""
    private static var lastFailureAt = Date.distantPast

    @discardableResult
    public static func run(_ source: String) async throws -> String {
        try await run(source, deadline: deadline)
    }

    static func run(_ source: String, deadline: TimeInterval) async throws -> String {
        let reply = Reply()
        return try await withCheckedThrowingContinuation { continuation in
            reply.continuation = continuation
            queue.async {
                // Still queued behind a script that's stuck: it was given up on, so it never runs late.
                guard reply.isPending else { return }
                reply.resolve(Result { try execute(source) })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                if reply.resolve(.failure(notAnswering(source))) { Log.error("AppleScript gave up after \(deadline)s — \(source.prefix(80))") }
            }
        }
    }

    public static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func execute(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: "with timeout of \(replyTimeout) seconds\n\(source)\nend timeout") else {
            throw HarkError("Invalid AppleScript.")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            report("\(number) \(message)", source)
            if number == -1743 {
                throw HarkError("Hark isn't allowed to control that app yet. Allow it in System Settings → Privacy & Security → Automation.")
            }
            if number == -1712 { throw notAnswering(source) }
            throw HarkError(message)
        }
        if result.descriptorType == typeAEList {
            return (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1)?.stringValue }.joined(separator: "\n")
        }
        return result.stringValue ?? ""
    }

    /// Callers often swallow these (`try?`), so each kind is logged, at most once per half minute.
    private static func report(_ failure: String, _ source: String) {
        guard failure != lastFailure || Date().timeIntervalSince(lastFailureAt) > 30 else { return }
        lastFailure = failure
        lastFailureAt = Date()
        Log.error("AppleScript \(failure) — \(source.prefix(80))")
    }

    private static func notAnswering(_ source: String) -> HarkError {
        let app = source.range(of: #"(?<=tell application ")[^"]+"#, options: .regularExpression).map { String(source[$0]) } ?? "The app"
        return HarkError("\(app) didn't answer in time. It may still be starting, or macOS may be asking whether Hark can control it.")
    }

    /// Resumes the caller exactly once: with the script's result, or with an error when the deadline passes first.
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<String, Error>?

        var isPending: Bool { lock.withLock { continuation != nil } }

        @discardableResult
        func resolve(_ result: Result<String, Error>) -> Bool {
            let waiting = lock.withLock { () -> CheckedContinuation<String, Error>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
            return waiting != nil
        }
    }
}
