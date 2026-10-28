import Foundation

/// The writing model: turns what you said into exact edit steps, given the text you're working in.
/// Claude Haiku through your Claude Code sign-in, kept running between requests (no process start per request),
/// warmed up when you press ⌥⌘, and shut down after ten idle minutes.
public actor EditorBrain {
    public static let shared = EditorBrain()

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var waiting: CheckedContinuation<String, Error>?
    private var turns = 0
    private var lastUse = Date()
    private var requestID = 0

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
    {"op":"agent"}  needs to see the screen, other apps, or several app steps — not a text edit

    Rules:
    - Do what they MEAN, never type an instruction. "type heading as Introduction" → insert "Introduction" then format heading. "write thanks in bold" → insert "thanks", select "thanks", format bold. "new paragraph" → insert "\\n\\n". "go to the end" → caret to end.
    - If [Recent] shows they're writing and the words read as content, insert them; if they describe an action on the text, do the action.
    - "cut" and "copy" must use the cut/copy ops (they fill the clipboard, so a later paste works); "remove"/"delete" use delete.
    - The quoted "text" IS exactly what gets selected, deleted, or cut: quote just that (one word → that word), exactly as it appears in [Text]. If it appears more than once, add "occurrence" (the nearest to the caret is the default). Never invent text that isn't there.
    - Clean speech when inserting: drop uh/um, fix capitalization and punctuation, keep their words.
    - Noise or nothing meaningful: {"ops":[]}.
    """

    /// Starts the model in the background so the first request doesn't wait for it.
    public func prewarm() {
        guard process == nil, let binary = ClaudeBrain.binary else { return }
        start(binary)
    }

    /// Sends one request; returns the model's reply text.
    public func ask(_ message: String) async throws -> String {
        guard let binary = ClaudeBrain.binary else { throw HarkError("Claude Code isn't installed.") }
        if turns >= 30 { stop() }  // keep the conversation short, so it stays fast
        if process == nil { start(binary) }
        guard let input else { throw HarkError("The writing model didn't start.") }
        lastUse = Date()
        turns += 1
        requestID += 1
        let id = requestID
        let line = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": message]]]] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: line) + Data("\n".utf8)
        let started = Date()
        let reply: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                input.write(data)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    await self?.timeOut(id)
                }
            }
        } onCancel: {
            Task { await self.cancelCurrent() }
        }
        Log.info(String(format: "Writing model answered in %.2fs", Date().timeIntervalSince(started)))
        scheduleIdleStop()
        return reply
    }

    private func start(_ binary: URL) {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-p", "--model", "haiku", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                             "--system-prompt", Self.instructions, "--disallowedTools", "advisor"]
        let workdir = Paths.appSupport.appendingPathComponent("claude-brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        process.currentDirectoryURL = workdir
        var env = ["HOME": Paths.home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "USER": NSUserName()]
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
        process.terminationHandler = { _ in Task { await owner.ended() } }
        do { try process.run() } catch { Log.error("Writing model failed to start: \(error.localizedDescription)"); return }
        self.process = process
        input = stdin.fileHandleForWriting
        buffer = Data()
        turns = 0
        Log.info("Writing model started")
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], json["type"] as? String == "result" else { continue }
            let continuation = waiting
            waiting = nil
            if (json["is_error"] as? Bool) == true {
                continuation?.resume(throwing: HarkError("The writing model couldn't answer (\(json["subtype"] as? String ?? "error")).") )
                stop()
            } else {
                continuation?.resume(returning: json["result"] as? String ?? "")
            }
        }
    }

    private func ended() {
        process = nil
        input = nil
        waiting?.resume(throwing: HarkError("The writing model stopped."))
        waiting = nil
    }

    private func timeOut(_ id: Int) {
        guard id == requestID, let continuation = waiting else { return }
        waiting = nil
        continuation.resume(throwing: HarkError("The writing model took too long."))
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
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        if Date().timeIntervalSince(lastUse) >= 590, waiting == nil, process != nil { stop(); Log.info("Writing model asleep") }
    }

    /// The plan out of the model's reply: its ops, and an optional note for the user.
    public static func plan(from reply: String) -> (ops: [[String: Any]], say: String) {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] else { return ([], "") }
        return (json["ops"] as? [[String: Any]] ?? [], json["say"] as? String ?? "")
    }
}
