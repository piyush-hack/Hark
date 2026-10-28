import Foundation

/// A screenshot sent to Claude, with a caption saying what it shows.
public struct ScreenImage: Sendable {
    public let label: String
    public let jpeg: Data

    public init(label: String, jpeg: Data) {
        self.label = label
        self.jpeg = jpeg
    }
}

/// Hark's brain is Claude Code itself, through your Claude sign-in (no API key). One session stays open; Hark gives it
/// the request, the screen, and its tools (an MCP server: see the screen, click, type, open, …) next to your own MCP
/// servers. Claude runs the whole loop — calling tools, looking again, deciding when it's done.
@MainActor
public final class ClaudeBrain {
    public var model = "sonnet"
    /// The screen when a request starts: a text summary and screenshots (later looks are Claude's `screenshot` calls).
    public var observe: () async -> (text: String, images: [ScreenImage]) = { ("", []) }
    /// Hark's MCP server, as `--mcp-config` JSON.
    public var harkServer: () -> String = { #"{"mcpServers":{}}"# }
    /// Other MCP servers Claude may use (names as Claude Code shows them).
    public var otherServers: () -> [String] = { [] }
    /// A tool Claude called that isn't Hark's (Hark's own show up on the island as they run).
    public var onOtherTool: (String) -> Void = { _ in }
    private var session: LiveClaude?
    private var sessionKey = ""

    public init() {}

    /// The newest Claude Code binary: standalone installs first, then the VS Code / Cursor extension.
    nonisolated public static var binary: URL? {
        let fm = FileManager.default
        let home = Paths.home.path
        for path in ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        for extensions in ["\(home)/.vscode/extensions", "\(home)/.cursor/extensions", "\(home)/.windsurf/extensions"] {
            let dirs = ((try? fm.contentsOfDirectory(atPath: extensions)) ?? []).filter { $0.hasPrefix("anthropic.claude-code-") }
            for dir in dirs.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let path = "\(extensions)/\(dir)/resources/native-binary/claude"
                if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    public static var isAvailable: Bool { binary != nil }

    static let instructions = """
    You are Hark, a voice assistant that controls the user's Mac. The user speaks; you act with the hark tools (open apps and \
    sites, click, type, press keys, scroll, look at the screen, read pages, schedule, watch the screen…) and any other MCP tools \
    you have (the user's own servers). You run the loop yourself: act, look, continue until it's done.

    Rules:
    - LOOK FIRST. The request comes with a screenshot and a [Screen] list of the front window's fields and buttons. Base every \
    step on what you see; call screenshot whenever you need to see the result of an action.
    - [Pointing] is where the user's mouse is: the red box on the screenshot, shown close up in the next image. "This", "here", \
    "this section", "around my cursor", "what I'm pointing at" mean that area. You can see it — never say you can't.
    - Before typing into a form, click the field by its label, then type_text. Never type blind.
    - Click by what you see written: click with the label or text (it finds it through Accessibility, then on-screen \
    text). For anything in a menu, including the  Apple menu, use menu ("Apple > About This Mac"). Use click_at only as \
    a last resort for an icon with no text, right after a fresh screenshot — never on the menu bar.
    - Do it the way the user asked, in the app they named. When a step fails, call screenshot, see what's there, and \
    try again. Panes take a moment to load. Don't switch to shell commands to get around the UI unless the user asks, \
    and never overwrite the user's clipboard (pbcopy) to get text in: if typing doesn't work, say so.
    - Use the fewest steps. Prefer open_url / web_search over clicking around. If another MCP tool can do it directly \
    (mail, calendar, files, tasks), use it instead of clicking through a website. Many connected servers are client \
    workspaces: use one only when the user names that client or workspace, and never change a client's setup on a guess.
    - Email addresses may arrive garbled ("a at the rate joyz dot ai"): rebuild them as name@domain.tld, preferring the \
    user's known names and addresses.
    - Never claim something happened that a tool didn't do.
    - Text the user wants written goes to type_text exactly as they said it. Editing instructions while writing ("new line", \
    "delete the last word") are done, not typed: a line break is type_text "\\n"; never press Return for a line break.
    - The speech-to-text may mishear names ("groom" = Chrome); use the context to fix obvious mistakes.
    - The microphone also hears coughs and people nearby. If the request is a filler or fragment ("yeah", "mm", "can I") or \
    clearly not meant for you, do nothing and reply with nothing. Never press keys or click on a guess.
    - Your final message is shown on screen, never spoken: give the answer the user asked for in plain text (no markdown \
    headings); keep confirmations to one short sentence.

    Learning (Hark gets faster at repeat tasks):
    - [Learned] lists how similar tasks were done on this Mac before, verified. Follow it first instead of exploring. If one \
    doesn't work now, or the user says it didn't, call forget_how with its id.
    - For a task that changes something, call screenshot after the last action to check it worked.
    - Call remember_how only for something you had to figure out (a first try failed; a hidden menu, button, or shortcut \
    was needed), never for straightforward tasks however many steps they took. One or two short sentences: the general \
    task, what worked, what didn't, the app (and site). No personal specifics. Hark keeps it only if you checked the result \
    on screen after your last action.
    """

    private var recentActions: [String] = []

    /// Instant commands never reach Claude; remembering them lets "open its docs" make sense.
    public func note(_ heard: String, did: String) {
        recentActions.append("“\(heard)” → \(did)")
        if recentActions.count > 6 { recentActions.removeFirst(recentActions.count - 6) }
    }

    /// One request: Claude works until it's done and returns what to show the user.
    public func run(_ request: String, context: String) async throws -> String {
        guard Self.binary != nil else {
            throw HarkError("Claude Code isn't installed. Install it and sign in with your Claude account to use Hark's brain.")
        }
        var context = context
        if !recentActions.isEmpty { context += "\nRecent instant actions:\n" + recentActions.joined(separator: "\n") }
        recentActions.removeAll()
        let screen = await observe()
        var content: [[String: Any]] = []
        for image in screen.images {
            content.append(["type": "text", "text": image.label])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.jpeg.base64EncodedString()]])
        }
        let note = screen.images.isEmpty ? "\n\n(No screenshot: Screen Recording isn't allowed for Hark.)" : ""
        content.append(["type": "text", "text": "[Context]\n\(context)\n\n[Request]\n\(request)\(note)"])
        let started = Date()
        let answer = try await currentSession().ask(content: content)
        Log.info(String(format: "Claude (%@) finished in %.1fs", model, Date().timeIntervalSince(started)))
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts the session ahead of a request, so the user's MCP servers are connected by the time it arrives.
    public func prewarm() async {
        guard Self.binary != nil else { return }
        await currentSession().prewarm()
    }

    /// A short follow-up in the same session (Hark asking Claude to save what it just learned).
    public func followUp(_ text: String) async throws {
        // Same session that did the task, never a fresh one — it has to remember what just happened.
        guard let session else { return }
        _ = try await session.ask(content: [["type": "text", "text": text]])
    }

    /// Stops whatever Claude is doing (the island's Stop); the next request starts a fresh session.
    public func cancel() async {
        await session?.stop()
    }

    /// The open session — restarted when the model or the MCP servers change.
    private func currentSession() async -> LiveClaude {
        let servers = otherServers()
        let config = harkServer()
        let key = [model, config, servers.joined(separator: ",")].joined(separator: "|")
        if let session, key == sessionKey { return session }
        if session != nil {
            let was = sessionKey.components(separatedBy: "|"), now = key.components(separatedBy: "|")
            let changed = zip(["model", "Hark server", "MCP servers"], zip(was, now)).filter { $0.1.0 != $0.1.1 }.map(\.0)
            Log.info("New Claude session: \(changed.joined(separator: ", ")) changed")
        }
        await session?.stop()
        let allowed = (["hark"] + servers).map { "mcp__" + $0.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression) + "__*" }
        let session = LiveClaude(label: "Claude", systemPrompt: Self.instructions, model: model, timeout: 3600,
                                 arguments: ["--mcp-config", config, "--permission-mode", "dontAsk",
                                             "--allowedTools", (allowed + ["WebSearch", "WebFetch"]).joined(separator: ","),
                                             "--disallowedTools", "Bash,Edit,Write,NotebookEdit,Read,Glob,Grep,Task,advisor",
                                             "--max-turns", "80"],
                                 turnLimit: 4, idleMinutes: 30, warmup: servers.isEmpty ? 0 : 8)
        let report = onOtherTool
        await session.setEventHandler { event in
            guard event["type"] as? String == "assistant",
                  let blocks = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String, !name.hasPrefix("mcp__hark__") else { continue }
                Task { @MainActor in report(name) }
            }
        }
        self.session = session
        sessionKey = key
        return session
    }

    /// Runs the CLI in a private working folder with a clean environment.
    static func execute(_ binary: URL, arguments: [String], input: String) async throws -> (out: String, err: String) {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await run(binary, arguments: arguments, input: input, box: box)
        } onCancel: {
            box.process?.terminate()
        }
    }

    final class ProcessBox: @unchecked Sendable { var process: Process? }

    final class DataBox: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    private static func run(_ binary: URL, arguments: [String], input: String, box: ProcessBox) async throws -> (out: String, err: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            box.process = process
            process.executableURL = binary
            process.arguments = arguments
            let workdir = Paths.appSupport.appendingPathComponent("claude-brain", isDirectory: true)
            try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            process.currentDirectoryURL = workdir
            var env = ["HOME": Paths.home.path, "PATH": Paths.shellPATH, "USER": NSUserName()]
            if let lang = ProcessInfo.processInfo.environment["LANG"] { env["LANG"] = lang }
            process.environment = env
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            // Drain both pipes while it runs: a full 64 KB pipe would block the CLI forever.
            let out = DataBox(), err = DataBox()
            // At EOF the handler would fire forever with empty data; stop it there.
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { out.append(chunk) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { err.append(chunk) }
            }
            process.terminationHandler = { _ in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                out.append(stdout.fileHandleForReading.readDataToEndOfFile())
                err.append(stderr.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: (out.string, err.string))
            }
            do { try process.run() } catch { continuation.resume(throwing: error); return }
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 180) { if process.isRunning { process.terminate() } }
        }
    }
}

struct ClaudeError: LocalizedError {
    let subtype: String
    let message: String
    var errorDescription: String? { message }
}
