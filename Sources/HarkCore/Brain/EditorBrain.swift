import Foundation

/// The writing model: turns what you said into exact edit steps, given the text you're working in.
public enum EditorBrain {
    /// Claude (Haiku by default) kept running between requests, warmed up when you press ⌥⌘.
    public static let shared = LiveClaude(label: "Writing model", systemPrompt: instructions, model: "haiku", timeout: 20,
                                          arguments: ["--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                                                      "--disallowedTools", "advisor"])

    static let instructions = """
    You are the hands of Hark, a Mac voice assistant, inside the text field the user is working in. Turn what they said into exact edits.

    You get [App], [Field] and [Text] (the field's text; ⟦|⟧ is the caret, ⟦…⟧ the selection), [Recent] (what was just done), and [Said] (speech-to-text: may have fillers, odd punctuation, mishearings).

    Reply with ONLY JSON: {"ops":[...]} and optionally "say":"short note for the user".
    Ops:
    {"op":"insert","text":"…"}  write at the caret, replacing any selection. "\\n" = new line, "\\n\\n" = new paragraph.
    {"op":"select","text":"exact words from [Text]"}  or {"op":"select","from":"first words","to":"last words"}; add "occurrence":"first|last|2" if not the nearest
    {"op":"caret","after":"words"} | {"op":"caret","before":"words"} | {"op":"caret","to":"start|end|line_start|line_end"}
    {"op":"delete","text":"words"} | {"op":"delete","from":"…","to":"…"} | {"op":"delete"} (the selection)
    {"op":"replace","text":"old words","with":"new words"}
    {"op":"cut"} {"op":"copy"} (selection, or add "text") {"op":"paste"}
    {"op":"format","style":"heading|subheading|title|body|bold|italic|underline|strikethrough|bullet|numbered|checklist|code|quote"}  (selection, or the caret's line for heading/list styles)
    {"op":"key","keys":"cmd+z"}  any shortcut
    {"op":"search","query":"…","where":"here|web|page|youtube|<site name>"}  here = this site's or app's own search; page = find on this page
    {"op":"agent"}  anything that isn't an edit to this text — a question, information, other apps or services, anything on screen. Hark's full assistant (with the screen and every tool) takes it.

    Rules:
    - You only edit this text. Never answer, explain, or refuse anything yourself: if it isn't an edit to [Text], reply {"ops":[{"op":"agent"}]}.
    - Do what they MEAN, never type an instruction. "type heading as Introduction" → insert "Introduction" then format heading. "write thanks in bold" → insert "thanks", select "thanks", format bold. "new paragraph" → insert "\\n\\n". "go to the end" → caret to end.
    - [Said] may be words to write here or a request for Hark; Hark couldn't tell from the words alone. Words meant for this field — a message to someone (even "call me when you land", "buy milk"), a note, a list item, a prompt for the chat box in [App] — insert them, cleaned up. A request for the assistant — to do something on the Mac or in the app (open, click, find, create a header, fill rows, send it), or a question for it to answer — {"ops":[{"op":"agent"}]}. In a spreadsheet cell or a search box, a whole sentence is almost always a request.
    - If [Recent] shows they're writing and the words read as content, insert them; if they describe an action on the text, do the action.
    - "cut" and "copy" must use the cut/copy ops (they fill the clipboard, so a later paste works); "remove"/"delete" use delete.
    - The quoted "text" IS exactly what gets selected, deleted, or cut: quote just that (one word → that word), exactly as it appears in [Text]. If it appears more than once, add "occurrence" (the nearest to the caret is the default). Never invent text that isn't there.
    - Clean speech when inserting: drop uh/um, fix capitalization and punctuation, keep their words.
    - Noise or nothing meaningful: {"ops":[]}.

    Writing session: with [Heard], they're dictating and Hark has already typed their words. [Before] is the text before this session (context only). [Written] has been checked already; [Just typed] follows it: Hark's typing of the newest speech, with spoken punctuation already applied. [Heard] is that speech, raw speech-to-text, in order.
    Reply ONLY {"text":"…"}: what [Written] + [Just typed] should become.
    - Fix what speech recognition got wrong in [Just typed], using the context: misheard words and names, a word said and then spelled out (write it once, as spelled: "Shawn, S E A N" → "Sean"), self-corrections ("ninety, no, sixty" → "sixty"), punctuation and capitals, joins between phrases ("the meeting. went well" → "the meeting went well").
    - If [Heard] has an instruction about the text ("put that in brackets", "scratch that", "I meant Friday", "it's spelled H A R K"), carry it out — it may change [Written]. Brackets are round ( ) unless they say square.
    - Otherwise leave [Written] exactly as it is, and never drop a phrase: keep their words; don't reword, add, summarise, or answer anything.
    """

    /// A writing pass's answer: the text the session should become (and, from older prompts, a request — ignored now).
    public static func session(from reply: String) -> (text: String?, ask: String?) {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] else { return (nil, nil) }
        let ask = (json["ask"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (json["text"] as? String, ask?.isEmpty == false ? ask : nil)
    }

    /// The plan out of the model's reply: its ops, and an optional note for the user.
    public static func plan(from reply: String) -> (ops: [[String: Any]], say: String) {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] else { return ([], "") }
        return (json["ops"] as? [[String: Any]] ?? [], json["say"] as? String ?? "")
    }
}

/// A Claude Code session kept running between requests: no process start per request, so each answer is just the
/// model's time. Sleeps after ten idle minutes; restarts on its own after 30 turns to stay quick.
public actor LiveClaude {
    public let label: String
    private let systemPrompt: String
    private var arguments: [String]
    private let timeout: UInt64
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var waiting: CheckedContinuation<String, Error>?
    private var turns = 0
    private var lastUse = Date()
    private var model: String

    private let turnLimit: Int
    /// Every event line from the session (tool calls as they happen, for the island).
    private var onEvent: (@Sendable ([String: Any]) -> Void)?

    /// Idle time before the session goes to sleep (frees its memory; the next request starts it again).
    private let idleSeconds: UInt64
    /// How old a fresh process must be before its first request: claude.ai connectors arrive a few seconds after start,
    /// and a request sent before then only sees the local servers.
    private let warmup: TimeInterval
    private var startedAt = Date.distantPast

    public init(label: String, systemPrompt: String, model: String, timeout: TimeInterval, arguments: [String], turnLimit: Int = 30,
                idleMinutes: Int = 10, warmup: TimeInterval = 0) {
        self.idleSeconds = UInt64(idleMinutes * 60)
        self.warmup = warmup
        self.label = label
        self.systemPrompt = systemPrompt
        self.model = model
        self.timeout = UInt64(timeout * 1_000_000_000)
        self.arguments = arguments
        self.turnLimit = turnLimit
    }

    public func setEventHandler(_ handler: @escaping @Sendable ([String: Any]) -> Void) { onEvent = handler }

    /// New tools or limits (e.g. which connectors are allowed): the next request starts a fresh session with them.
    public func setArguments(_ value: [String]) {
        guard value != arguments else { return }
        arguments = value
        stop()
    }

    /// Switches the writing model; the running one stops so the next request starts with the new one.
    public func setModel(_ value: String) {
        guard value != model else { return }
        model = value
        stop()
    }
    private var requestID = 0


    /// Starts the model in the background so the first request doesn't wait for it.
    public func prewarm() {
        guard process == nil, let binary = ClaudeBrain.binary else { return }
        start(binary)
    }

    /// Sends one request; returns the model's reply text.
    public func ask(_ message: String) async throws -> String {
        try await ask(content: [["type": "text", "text": message]])
    }

    /// Sends one request made of text and image blocks; returns the model's final reply text.
    /// `keepOpen`: don't start a fresh session yet even if this one is used up — a follow-up (`followUp: true`) about this
    /// very request is coming, and it must reach the conversation that remembers it. Then call `restartIfUsedUp`.
    public func ask(content: [[String: Any]], keepOpen: Bool = false, followUp: Bool = false) async throws -> String {
        guard let binary = ClaudeBrain.binary else { throw HarkError("Claude Code isn't installed.") }
        // One request at a time: a background check and a spoken request can't share the one reply slot.
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if turns >= turnLimit, !followUp { stop() }  // keep the conversation short, so it stays fast
        if process == nil { start(binary) }
        let wait = warmup - Date().timeIntervalSince(startedAt)
        if turns == 0, wait > 0 {
            Log.info(String(format: "%@ waiting %.1fs for connectors", label, wait))
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        guard let input else { throw HarkError("\(label) didn't start.") }
        lastUse = Date()
        turns += 1
        requestID += 1
        let id = requestID
        let line = ["type": "user", "message": ["role": "user", "content": content]] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: line) + Data("\n".utf8)
        let started = Date()
        let reply: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                input.write(data)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: self?.timeout ?? 20_000_000_000)
                    await self?.timeOut(id)
                }
            }
        } onCancel: {
            Task { await self.cancelCurrent() }
        }
        Log.info(String(format: "%@ answered in %.2fs", label, Date().timeIntervalSince(started)))
        scheduleIdleStop()
        // Used up: start the next session now, so it's warm (its MCP servers connected) for the next request.
        if turns >= turnLimit, !keepOpen {
            stop()
            start(binary)
        }
        return reply
    }

    /// After an `ask` with `keepOpen` and no follow-up: if the session is used up, start the next one now, warm.
    public func restartIfUsedUp() async {
        guard turns >= turnLimit, let binary = ClaudeBrain.binary else { return }
        await acquire()
        defer { release() }
        guard turns >= turnLimit else { return }
        stop()
        start(binary)
    }

    private var busy = false
    private var queued: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { queued.append($0) }
    }

    private func release() {
        if queued.isEmpty { busy = false } else { queued.removeFirst().resume() }
    }

    private func start(_ binary: URL) {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-p", "--model", model, "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--system-prompt", systemPrompt] + arguments
        let workdir = Paths.appSupport.appendingPathComponent("claude-brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        process.currentDirectoryURL = workdir
        var env = ["HOME": Paths.home.path, "PATH": Paths.shellPATH, "USER": NSUserName()]
        if let lang = ProcessInfo.processInfo.environment["LANG"] { env["LANG"] = lang }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let owner = self
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            Task { await owner.receive(chunk) }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let id = ObjectIdentifier(finished)
            Task { await owner.ended(id, status: status) }
        }
        do { try process.run() } catch { Log.error("\(label) failed to start: \(error.localizedDescription)"); return }
        self.process = process
        input = stdin.fileHandleForWriting
        buffer = Data()
        turns = 0
        startedAt = Date()
        Log.info("\(label) started")
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            onEvent?(json)
            guard json["type"] as? String == "result" else { continue }
            let continuation = waiting
            waiting = nil
            if (json["is_error"] as? Bool) == true {
                continuation?.resume(throwing: HarkError("\(label) couldn't answer (\(json["subtype"] as? String ?? "error")).") )
                stop()
            } else {
                continuation?.resume(returning: json["result"] as? String ?? "")
            }
        }
    }

    /// A process ended. Only the current one matters: an old one finishing after its replacement started is ignored.
    private func ended(_ id: ObjectIdentifier, status: Int32) {
        guard let process, ObjectIdentifier(process) == id else { return }
        Log.info("\(label) process exited (status \(status))")
        self.process = nil
        input = nil
        waiting?.resume(throwing: HarkError("\(label) stopped."))
        waiting = nil
    }

    private func timeOut(_ id: Int) {
        guard id == requestID, let continuation = waiting else { return }
        waiting = nil
        continuation.resume(throwing: HarkError("\(label) took too long."))
        stop()
    }

    private func cancelCurrent() {
        guard let continuation = waiting else { return }
        waiting = nil
        continuation.resume(throwing: CancellationError())
        stop()  // its answer would arrive for the wrong request
    }

    public func stop() {
        process?.terminate()
        process = nil
        input = nil
    }

    private func scheduleIdleStop() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.idleSeconds ?? 600) * 1_000_000_000)
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        if Date().timeIntervalSince(lastUse) >= Double(idleSeconds) - 10, waiting == nil, process != nil { stop(); Log.info("\(label) asleep") }
    }

}
