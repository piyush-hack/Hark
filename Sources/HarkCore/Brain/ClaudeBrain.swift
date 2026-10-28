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

/// Uses your Claude subscription (through the Claude Code CLI you're already signed in to) as Hark's brain.
/// No API key and no extra cost: Claude gets the request, the screen context, and Hark's tool list, and
/// answers with a JSON plan that Hark executes — looping when Claude needs to see results first.
@MainActor
public final class ClaudeBrain {
    public var model = "sonnet"
    /// The screen right now: a text summary (fields, buttons, focus) and screenshots Claude can read.
    public var observe: () async -> (text: String, images: [ScreenImage]) = { ("", []) }
    public var runTool: (ToolCall) async -> String = { _ in "Tool unavailable." }
    private var sessionID: String?
    private var lastUse = Date.distantPast
    private var roundsInSession = 0

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

    static let instructions: String = {
        let catalog = Tools.all.compactMap { tool -> String? in
            guard let fn = tool["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
            let description = fn["description"] as? String ?? ""
            let params = (fn["parameters"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
            let args = params.keys.sorted().map { key -> String in
                let p = params[key] ?? [:]
                let options = (p["enum"] as? [String]).map { " one of: " + $0.joined(separator: "|") } ?? ""
                return "\(key): \(p["type"] as? String ?? "string")\(options)"
            }.joined(separator: ", ")
            return "- \(name)(\(args)) — \(description)"
        }.joined(separator: "\n")
        return """
        You are Hark, a voice assistant that fully controls the user's Mac. You never act yourself: you reply with a JSON plan that Hark executes.

        Tools Hark can run:
        \(catalog)

        Reply with ONLY one JSON object, no prose, no code fences:
        {"steps":[{"tool":"<name>","args":{...}}], "continue": <true|false>, "say":"<your answer, shown to the user as text>"}

        Rules:
        - LOOK FIRST. You get a screenshot of the screen plus a [Screen] list of the front window's fields, buttons, and focus. Read emails, pages, and anything visible straight from the screenshot. Base every step on what you see.
        - [Pointing] tells you where the user's mouse pointer is. The red box on the screenshot is the area around it, and the close-up image shows that area sharply. "This", "here", "this section", "around my cursor", "what I'm pointing at / highlighting" mean that area: answer about it directly. You can see it — never say you can't see the cursor.
        - Before typing into a form, click the right field by its label (e.g. "To", "Subject", "Message Body"), then type_text. Never type blind.
        - After acting, if you need to verify or continue, set "continue": true — you'll get the new [Screen].
        - Use the fewest steps. Prefer web_search/open_url over clicking around.
        - Email addresses may arrive garbled ("a at the rate joyz dot ai", "at the red"): rebuild them as name@domain.tld, preferring the user's known names/addresses.
        - Set "continue": true only when you must see results before finishing (e.g. after read_screen or read_page, or to pick something on a page). Hark will send you the results.
        - "say" is shown on screen, never spoken. Give the full answer the user asked for (a summary, the details, a list) in plain text; keep pure confirmations short. When continuing, leave it empty.
        - Never claim something happened that a step didn't do. If no tool can do it, say so with no steps.
        - Text the user wants written goes to type_text exactly as they said it — never answer that text yourself.
        - Dictation: when recent actions show typing (Type “…”), the user is writing. Words that belong in the text go to type_text exactly. Editing or formatting instructions, however they're phrased, are done instead of typed: a line break is type_text "\n", a blank line "\n\n", deleting the last word is press_keys "option+backspace", and so on. Never press Return to make a line break (it sends chats).
        - Without [Pointing], "this/it" means the current screen, selection, or page in the context.
        - The speech-to-text may mishear names (e.g. "groom" = Chrome); use the context to fix obvious mistakes.
        - Questions you can answer from knowledge: no steps, just "say".
        - The microphone also hears coughs, fillers, and people nearby. If the request is just a filler or fragment ("yeah", "ah yeah", "mm", "can I") or clearly isn't meant for you, do nothing: no steps and an empty "say". Never press keys or click on a guess.
        """
    }()

    private var recentActions: [String] = []

    /// Instant commands never reach Claude; remembering them lets "open its docs" make sense.
    public func note(_ heard: String, did: String) {
        recentActions.append("“\(heard)” → \(did)")
        if recentActions.count > 6 { recentActions.removeFirst(recentActions.count - 6) }
    }

    public func run(_ request: String, context: String) async throws -> String {
        guard let binary = Self.binary else {
            throw HarkError("Claude Code isn't installed. Install it and sign in with your Claude account to use Hark's brain.")
        }
        // Screenshots make sessions heavy; start fresh after 5 idle minutes or a dozen rounds to stay fast.
        if Date().timeIntervalSince(lastUse) > 300 || roundsInSession > 12 { sessionID = nil; roundsInSession = 0 }
        var context = context
        if !recentActions.isEmpty { context += "\nRecent instant actions:\n" + recentActions.joined(separator: "\n") }
        recentActions.removeAll()
        var message = "[Context]\n\(context)\n\n[Request]\n\(request)"
        var images = await observe().images
        // No fixed round limit: Claude keeps going until it's done. The island's Stop button cancels.
        for _ in 0..<60 {
            try Task.checkCancellation()
            let reply: String
            do {
                reply = try await ask(message, images: images, binary: binary)
            } catch let error as ClaudeError {
                // One automatic retry in a fresh session, carrying the current request forward.
                Log.info("Retrying after \(error.subtype)")
                reply = try await ask("[Context]\n\(context)\n\n[Request]\n\(request)\n\n" + message, images: images, binary: binary)
            }
            guard let plan = Self.parsePlan(reply) else {
                // Not JSON: treat it as a plain answer.
                return reply.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var results: [String] = []
            for step in plan.steps {
                try Task.checkCancellation()
                let output = await runTool(step)
                results.append("\(step.name): \(output.prefix(3000))")
            }
            if plan.continueAfter, !plan.steps.isEmpty {
                try await Task.sleep(nanoseconds: 400_000_000)  // let the UI settle before looking again
                let screen = await observe()
                // Later rounds get just the full screenshot (the red box still marks the area): keeps long runs light.
                images = Array(screen.images.prefix(1))
                message = "[Results]\n" + results.joined(separator: "\n\n") + "\n\n[Screen]\n\(screen.text)\n\nContinue. Reply with the next JSON plan."
                continue
            }
            if !plan.say.isEmpty { return plan.say }
            return plan.steps.isEmpty ? "" : "Done."
        }
        return "That took too many steps, so I stopped."
    }

    private func ask(_ message: String, images: [ScreenImage], binary: URL) async throws -> String {
        // Plan-only: no built-in tools, no MCP servers, and no advisor (it needs extra turns and fails the call).
        var arguments = ["-p", "--model", model, "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--max-turns", "3", "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                         "--system-prompt", Self.instructions, "--disallowedTools", "advisor"]
        if let sessionID { arguments += ["--resume", sessionID] }
        var content: [[String: Any]] = []
        for image in images {
            content.append(["type": "text", "text": image.label])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": images.isEmpty ? message + "\n\n(No screenshot: Screen Recording isn't allowed for Hark.)" : message])
        let line = ["type": "user", "message": ["role": "user", "content": content]] as [String: Any]
        let input = String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self) + "\n"
        let started = Date()
        let (output, errors) = try await Self.execute(binary, arguments: arguments, input: input)
        try Task.checkCancellation()
        let result = output.split(separator: "\n").reversed().lazy
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .first { $0["type"] as? String == "result" }
        guard let json = result else {
            // The CLI quit without an answer (crash, timeout, network): keep the details in the log, not on screen.
            let detail = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.error("Claude gave no result after \(Int(Date().timeIntervalSince(started)))s. stderr: \(detail.suffix(600)) · stdout tail: \(output.suffix(400))")
            sessionID = nil
            let reason = detail.split(separator: "\n").last.map(String.init) ?? ""
            throw ClaudeError(subtype: "no_result", message: "Claude stopped without answering" + (reason.isEmpty ? "." : ": \(reason.prefix(160))"))
        }
        if (json["is_error"] as? Bool) == true {
            let subtype = json["subtype"] as? String ?? "unknown"
            Log.error("Claude error (\(subtype)): \(String(describing: json["result"] ?? json["errors"] ?? "").prefix(300))")
            sessionID = nil
            throw ClaudeError(subtype: subtype, message: (json["result"] as? String) ?? "Claude couldn't finish (\(subtype)).")
        }
        sessionID = json["session_id"] as? String ?? sessionID
        lastUse = Date()
        roundsInSession += 1
        Log.info(String(format: "Claude (%@) answered in %.1fs · %d image(s)", model, Date().timeIntervalSince(started), images.count))
        return json["result"] as? String ?? ""
    }

    struct Plan {
        var steps: [ToolCall]
        var continueAfter: Bool
        var say: String
    }

    static func parsePlan(_ text: String) -> Plan? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        let steps = (json["steps"] as? [[String: Any]] ?? []).compactMap { step -> ToolCall? in
            guard let name = step["tool"] as? String else { return nil }
            let call = Tools.calls(in: ["tool_calls": [["function": ["name": name, "arguments": step["args"] ?? [:]]]]])
            return call.first
        }
        return Plan(steps: steps, continueAfter: json["continue"] as? Bool ?? false, say: json["say"] as? String ?? "")
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
            var env = ["HOME": Paths.home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "USER": NSUserName()]
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
