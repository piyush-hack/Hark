import AppKit
import Combine

public enum EnginePhase: Equatable, Sendable { case idle, listening, transcribing, thinking, working, announcing }
public enum ListenMode: Sendable { case command, dictation }

public struct Step: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable { case pending, running, done, failed }
    public let id = UUID()
    public var title: String
    public var status: Status

    public init(title: String, status: Status) {
        self.title = title
        self.status = status
    }
}

public struct ActivityEntry: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var heard: String
    public var result: String
    public var ok: Bool
}

public enum ModelState: Equatable, Sendable { case asleep, loading, ready, unavailable(String) }

public struct Highlight: Equatable, Sendable {
    public enum Style: Sendable { case confirm, fired, looking }
    public let id = UUID()
    public let rect: CGRect
    public let style: Style
}

/// Hark's brain stem: owns listening, understanding, and doing. The UI only observes it.
@MainActor
public final class HarkEngine: ObservableObject {
    @Published public private(set) var phase: EnginePhase = .idle
    @Published public private(set) var mode: ListenMode = .command
    /// Tap ⌥⌘ instead of holding: Hark keeps listening (and acting) until you tap ⌥⌘ again or say "stop listening".
    @Published public private(set) var handsFree = false
    @Published public private(set) var transcript = ""
    /// Mic level lives in its own object so only the orb redraws while you talk.
    public let meter = AudioLevel()
    public var level: Float { meter.value }
    @Published public private(set) var steps: [Step] = []
    @Published public private(set) var reply = "" {
        didSet { if !reply.isEmpty { nowDoing = reply; replyAt = Date() } }
    }
    /// What Hark is doing, or last did: the step it's on, or its answer. Unlike `steps` and `reply`, it stays when a
    /// hands-free turn ends, so the island keeps showing what just happened instead of "listening".
    @Published public private(set) var nowDoing = ""
    private var replyAt = Date.distantPast
    /// The start of a sentence that came with a pause after it ("Even though I"): joined to what you say next.
    private var heldFragment: (text: String, at: Date)?
    @Published public private(set) var confirmationPrompt: String?
    /// "Yes, don't ask again": every confirmation is approved until Hark quits.
    @Published public private(set) var approveForSession = false
    /// Hark opened the mic itself to hear the answer to its question.
    @Published public private(set) var listeningForAnswer = false
    private var answerHeard = ""
    /// Phrases of your voice Hark has learned; it filters other voices once it has `VoiceID.samplesNeeded`.
    @Published public private(set) var voiceSamples = 0
    /// When you tapped ⌥⌘ for hands-free: what's said in the next few seconds is almost surely you.
    private var handsFreeStartedAt = Date.distantPast
    /// "Teach my voice" is running: phrases are learned, not acted on.
    @Published public private(set) var learningVoice = false
    private var learningStarted = Date()
    /// Counts every tick-tick, so the island can bounce in time with the sound.
    @Published public private(set) var ticks = 0
    @Published public private(set) var activity: [ActivityEntry] = []
    @Published public private(set) var speechModel: ModelState = .asleep
    @Published public private(set) var brainModel: ModelState = .asleep
    @Published public var settings: HarkSettings { didSet { settingsChanged(oldValue) } }
    /// A region to outline on screen: where a watcher is, or what just triggered.
    @Published public private(set) var highlight: Highlight?

    public let scheduler = Scheduler()
    public let browser = Browser()
    public let claudeBrain = ClaudeBrain()
    /// Hark's actions as an MCP server for Claude Code.
    private let mcp = MCPServer()
    /// When Claude last acted, and last looked at the screen, across requests (learning needs a look after acting).
    private var agentActedAt = Date.distantPast
    private var agentLookedAt = Date.distantPast
    private var agentLessons: [Lesson] = []
    /// How much working out the current Claude run took: enough of it, and Hark asks Claude whether it learned something.
    private var effort = RunEffort()
    /// How-tos learned from tasks Claude verified on screen; the next similar request starts from them.
    public let lessonBook = LessonBook()
    private let textEditor = TextEditor()
    /// What the writing model just did, so "undo that" and "keep going" make sense.
    private var recentEdits: [String] = []
    public var brainAvailable: Bool { ClaudeBrain.isAvailable }
    public var parser = CommandParser()

    private let capture = AudioCapture()
    private let segmenter = Segmenter()
    private var audioStream: AsyncStream<[Float]>.Continuation?
    private var listenTask: Task<Void, Never>?
    private var pendingText = ""
    /// Audio behind `pendingText`; re-transcribed together with the next phrase so short bits get context.
    private var pendingAudio: [Float] = []
    /// What was heard this hold: phrases already acted on, and phrases still waiting (re-transcribed as they grow).
    private var committedHeard = ""
    private var pendingHeard = ""
    private var dictation = ""
    private var heardThisTurn = ""
    private var typingContinues = false
    /// Where and when you last wrote something: "writing mode" only lasts while you're still at it.
    private var typingApp: pid_t?
    private var lastTypedAt = Date.distantPast
    /// The request running right now, so saying it again while it's slow doesn't do it twice.
    private var running: Command?
    /// The last search run mid-sentence, so "…in Tokyo" can refine it.
    private var earlySearch: (query: String, site: SearchSite)?
    public private(set) var isHoldingHotkey = false
    /// Dry run: plan and log commands without doing anything (for testing with recordings).
    public var dryRun = false
    public private(set) var dryRunLog: [(seconds: Double, title: String)] = []
    private var consumedSamples = 0
    private var holdAudio: [Float] = []
    /// Where the pointer was when the user let go — what "here" means.
    private var pointAtRelease: CGPoint?
    /// The area under the pointer for the current Claude request (outlined on its screenshot, sent close up).
    private var pointing: (point: CGPoint, app: String?, rect: CGRect)?
    /// False for automation and watcher runs: the pointer means nothing to them.
    private var turnFromUser = true
    /// This turn came from the microphone (so it may be a cough or someone else talking), not typed or automated.
    private var heardBySpeech = false
    public var isBusy: Bool { runner != nil || !queue.isEmpty || phase == .transcribing }

    private var queue: [(Command, String)] = []
    private var runner: Task<Void, Never>?
    private var confirmation: CheckedContinuation<Bool, Never>?
    private var housekeeping: Timer?
    private var hideWork: DispatchWorkItem?
    private var turnResults: [String] = []
    private var turnOK = true

    public init() {
        let settings = HarkSettings.load()
        self.settings = settings
        claudeBrain.harkServer = { [weak self] in self?.mcp.configJSON ?? #"{"mcpServers":{}}"# }
        claudeBrain.otherServers = { Connectors.usable().filter { $0 != "hark" } }
        claudeBrain.onOtherTool = { [weak self] name in
            Log.info("  ↳ Use " + Self.toolDisplayName(name))
            self?.addStep("Use " + Self.toolDisplayName(name), status: .done)
        }
        claudeBrain.observe = { [weak self] in
            guard let self else { return ("", []) }
            return (await self.screenSummary(), await self.screenImages())
        }
        browser.preferred = { [weak self] in self?.settings.preferredBrowser }
        browser.keyboardGate = { [weak self] in await self?.waitForKeysReleased() }
        textEditor.keyboardGate = { [weak self] in await self?.waitForKeysReleased() }
        capture.voiceProcessing = settings.noiseSuppression
        capture.onLevel = { [weak self] value in
            DispatchQueue.main.async { self?.meter.push(value) }
        }
        loadActivity()
        let english = settings.englishSpeechModel
        Task { await Transcriber.shared.setVersion(english ? .v2 : .v3) }
        let writer = settings.writerModel
        Task { await EditorBrain.shared.setModel(writer) }
    }

    /// Call once at launch from the app (not from the CLI).
    public func start() {
        // Read the login shell's PATH now, off the main thread, so nothing on it ever waits for the shell.
        DispatchQueue.global(qos: .utility).async { _ = Paths.shellPATH }
        scheduler.onFire = { [weak self] automation, context in self?.automationFired(automation, context: context) }
        scheduler.start()
        housekeeping = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tidyMemory() }
        }
        Task { await segmenter.prepare() }
        capture.prewarm()
        startToolServer()
    }

    // MARK: Claude's tools

    /// Opens Hark's MCP server and learns which MCP servers Claude Code has on this Mac.
    private func startToolServer() {
        mcp.tools = { await MainActor.run { Self.mcpTools() } }
        mcp.call = { [weak self] name, arguments in
            guard let self else { return ([["type": "text", "text": "Hark isn't running."]], true) }
            return await self.agentTool(name, arguments)
        }
        Task {
            do { try await mcp.start() } catch { Log.error("Hark's tools couldn't start: \(error.localizedDescription)") }
            // Learn which MCP servers are connected (claude.ai ones take a few seconds), then open Claude's session with
            // all of them allowed, so they're connected before the first request.
            _ = await Connectors.discover()
            await claudeBrain.prewarm()
        }
    }

    /// Hark's tools in MCP form, plus the ones only Claude uses: screenshot, remember_how, forget_how.
    public static func mcpTools() -> [[String: Any]] {
        var tools = Tools.all.compactMap { tool -> [String: Any]? in
            guard let fn = tool["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
            return ["name": name, "description": fn["description"] as? String ?? "", "inputSchema": fn["parameters"] ?? ["type": "object"]]
        }
        func extra(_ name: String, _ description: String, _ properties: [String: [String: String]], _ required: [String]) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }
        tools.append(extra("screenshot", "See the screen now: a screenshot (with the pointer's area boxed) and the front window's fields and buttons.", [:], []))
        tools.append(extra("remember_how", "Save how a task is done on this Mac, after you checked on screen that it worked. General, no personal specifics.",
                           ["task": ["type": "string", "description": "General task, e.g. delete a note in Notes"],
                            "how": ["type": "string", "description": "What worked, and what didn't"],
                            "app": ["type": "string", "description": "App it was done in"],
                            "site": ["type": "string", "description": "Website domain, if any"]], ["task", "how", "app"]))
        tools.append(extra("forget_how", "A [Learned] how-to didn't work: drop it.", ["id": ["type": "string", "description": "Its id, e.g. L3"]], ["id"]))
        return tools
    }

    /// Runs one tool for Claude and returns MCP content.
    func agentTool(_ name: String, _ arguments: [String: Any]) async -> (content: [[String: Any]], isError: Bool) {
        let text = { (value: String) in [["type": "text", "text": value]] as [[String: Any]] }
        switch name {
        case "screenshot":
            agentLookedAt = Date()
            effort.looked()
            addStep("Look at the screen", status: .done)
            Log.info("  ↳ Look at the screen")
            var content: [[String: Any]] = []
            for image in await screenImages() {
                content.append(["type": "text", "text": image.label])
                content.append(["type": "image", "data": image.jpeg.base64EncodedString(), "mimeType": "image/jpeg"])
            }
            content.append(["type": "text", "text": "[Screen]\n" + (await screenSummary())])
            return (content, false)
        case "remember_how":
            let task = (arguments["task"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let how = (arguments["how"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty, !how.isEmpty else {
                Log.info("Not learning: remember_how came without task and how (it sent: \(arguments.keys.sorted().joined(separator: ", ")))")
                return (text("Not saved: give `task` (the general task) and `how` (what worked, and what didn't) — those exact names."), true)
            }
            // Only success Claude saw with its own eyes, after the last action, is worth keeping. The action may be in an
            // earlier request: "remember how you did that" comes right after the task.
            guard agentActedAt > .distantPast, agentLookedAt > agentActedAt else {
                let nothingDone = agentActedAt == .distantPast
                Log.info("Not learning “\(task)”: \(nothingDone ? "nothing has been done since Hark started" : "nothing was checked after the last action")")
                return (text(nothingDone ? "Not saved: nothing has been done since Hark started, so there's no checked result to learn from."
                                         : "Not saved: call screenshot after your last action and check it worked first."), true)
            }
            let app = arguments["app"] as? String ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            lessonBook.learn(task: task, how: how,
                             app: AppCatalog.shared.resolve(app)?.name ?? app,
                             site: (arguments["site"] as? String ?? "").replacingOccurrences(of: "www.", with: ""))
            return (text("Saved."), false)
        case "forget_how":
            let id = arguments["id"] as? String ?? ""
            lessonBook.failed(id)
            agentLessons.removeAll { $0.id == id }
            return (text("Noted."), false)
        default:
            // Looking (screen, page, or a read-only shell check like ls) confirms; anything else is an action.
            let command = (arguments["command"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let readOnlyShell = name == "run_shell" && !Shell.needsConfirmation(command)
                && command.matches(#"^(?:sleep \d+;\s*)?(?:ls|cat|head|tail|wc|find|mdfind|grep|stat|du|df|pgrep|ps|sw_vers|defaults read|which|file|echo|mdls)\b"#)
            let call = ToolCall(name: name, arguments: arguments.mapValues { value in
                switch value {
                case let string as String: return string
                case let number as NSNumber: return number.stringValue
                default: return String(describing: value)
                }
            })
            if ["read_screen", "read_page"].contains(name) || readOnlyShell {
                agentLookedAt = Date()
                effort.looked()
            } else if !["list_tasks", "wait"].contains(name) {
                agentActedAt = Date()
                effort.acted(name, call.arguments)
            }
            let result = await runTool(call)
            if result.hasPrefix("Error:") { effort.failed() }
            return (text(result), result.hasPrefix("Error:"))
        }
    }

    /// "mcp__claude_ai_Google_Drive__search" → "Google Drive: search".
    static func toolDisplayName(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3 else { return name }
        let server = parts[1].replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ")
        return "\(server): \(parts[2...].joined(separator: " ").replacingOccurrences(of: "_", with: " "))"
    }

    public func shutdown() {
        capture.stop()
    }

    // MARK: Hotkey lifecycle

    public func beginListening(mode: ListenMode) {
        guard phase != .listening else { return }
        hideWork?.cancel()
        isHoldingHotkey = true
        self.mode = mode
        pointAtRelease = nil
        // The writing model and Claude's session start while you talk, so they're ready when you finish the sentence.
        if mode == .command { Task { await EditorBrain.shared.prewarm(); await claudeBrain.prewarm() } }
        turnFromUser = true
        heardBySpeech = true
        transcript = ""
        dictation = ""
        answerHeard = ""
        if confirmationPrompt == nil { heardThisTurn = "" }
        typingContinues = false
        earlySearch = nil
        committedHeard = ""
        pendingHeard = ""
        if confirmationPrompt == nil {
            pendingText = ""
            pendingAudio = []
            steps = []
            reply = ""
            turnResults = []
            turnOK = true
        }
        phase = .listening
        let pressed = Date()
        let stream = AsyncStream<[Float]> { continuation in self.audioStream = continuation }
        let continuation = audioStream
        capture.onSamples = { samples in continuation?.yield(samples) }
        if speechModel != .ready { speechModel = .loading }
        listenTask = Task { [weak self] in await self?.consume(stream) }
        // The mic starts on its own queue; the island is already up and nothing waits on this.
        capture.start { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let took):
                    Log.info(String(format: "Mic live in %.0f ms (press → ready %.0f ms)", took * 1000, Date().timeIntervalSince(pressed) * 1000))
                case .failure(let error):
                    self?.fail("Microphone unavailable: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Feeds a recording through the same pipeline as the live mic (in dry-run mode) and returns
    /// when each command would have run, in seconds of audio. The key counts as held until the end.
    public func simulate(_ samples: [Float]) async -> [(seconds: Double, title: String)] {
        dryRun = true
        dryRunLog = []
        consumedSamples = 0
        isHoldingHotkey = true
        mode = .command
        committedHeard = ""; pendingHeard = ""; pendingText = ""; pendingAudio = []
        typingContinues = false; earlySearch = nil; heardThisTurn = ""
        phase = .listening
        var continuation: AsyncStream<[Float]>.Continuation?
        let stream = AsyncStream<[Float]> { continuation = $0 }
        let task = Task { await self.consume(stream) }
        var index = 0
        while index < samples.count {
            continuation?.yield(Array(samples[index..<min(index + 1_600, samples.count)]))
            index += 1_600
        }
        isHoldingHotkey = false
        phase = .transcribing
        continuation?.finish()
        await task.value
        while runner != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        return dryRunLog
    }

    /// Hotkey combo was part of a shortcut (e.g. ⌥⌘I): drop everything silently.
    public func cancelListening() {
        isHoldingHotkey = false
        handsFree = false
        capture.stop()
        audioStream?.finish()
        audioStream = nil
        listenTask?.cancel()
        listenTask = nil
        if phase == .listening { phase = .idle }
    }

    /// Keep listening without holding the keys; keystrokes then run live too.
    public func startHandsFree() {
        if phase != .listening { beginListening(mode: .command) }
        handsFree = true
        handsFreeStartedAt = Date()
        isHoldingHotkey = false
        Log.info("Hands-free listening on")
    }

    public func endListening() {
        handsFree = false
        isHoldingHotkey = false
        guard audioStream != nil else { return }
        pointAtRelease = RegionPicker.mouse
        capture.stop()
        meter.value = 0
        if phase == .listening { phase = .transcribing }
        audioStream?.finish()
        audioStream = nil
    }

    private func consume(_ stream: AsyncStream<[Float]>) async {
        await segmenter.prepare()
        await segmenter.reset()
        let loader = Task { try await Transcriber.shared.prepare() }
        for await samples in stream {
            if Task.isCancelled { return }
            consumedSamples += samples.count
            if settings.keepRecordings, holdAudio.count < 16_000 * 60 { holdAudio.append(contentsOf: samples) }
            for segment in await segmenter.append(samples) {
                await transcribePhrase(segment)
            }
            let quiet = await segmenter.quietSeconds
            // A ~1 s pause means the thought is finished: run whatever is still waiting, keys held or not.
            // …unless it stops on "type" or "create a": then give the rest of the sentence up to 3 s to arrive.
            if quiet >= 1.0, !pendingText.isEmpty, mode == .command, quiet >= 3 || !CommandParser.endsMidThought(pendingText) { flushPending() }
            // A held sentence start ("Even though I") gets ~2 s of quiet for the rest to arrive, then is taken as it is.
            if let held = heldFragment, mode == .command, quiet >= 2.0 || Date().timeIntervalSince(held.at) > 8 { flushHeld() }
            // Hands-free stays on until ⌥⌘ is tapped again, however long it's quiet (voice learning: 40 s at most).
            if learningVoice, Date().timeIntervalSince(learningStarted) > 40 { endListening() }
        }
        if Task.isCancelled { return }
        let rest = await segmenter.flush()
        _ = try? await loader.value
        if !rest.isEmpty || !pendingAudio.isEmpty { await transcribePhrase(rest) }
        saveRecording()
        ingestFinal()
    }

    /// Opt-in tuning data: the whole hold as a WAV plus what Hark heard, newest 20 kept.
    private func saveRecording() {
        defer { holdAudio = [] }
        guard settings.keepRecordings, holdAudio.count > 8_000, !dryRun else { return }
        let folder = Paths.appSupport.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(stamp).wav")
        var data = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let pcm = holdAudio.map { Int16(max(-1, min(1, $0)) * 32_767) }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(16_000)); put(UInt32(32_000)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count * 2))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try? data.write(to: url)
        try? heardThisTurn.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        let old = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.dropFirst(20)
        for file in old {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("txt"))
        }
    }

    /// Transcribes a phrase — together with any still-pending audio, so "Type in" + "hello, how are you"
    /// is heard as one sentence instead of two context-free fragments.
    private func transcribePhrase(_ segment: [Float]) async {
        if learningVoice { return await learnVoiceSample(segment) }
        // Hands-free hears the whole room: only your voice gets through (checked before transcribing, ~30 ms).
        if settings.voiceMatch, handsFree || listeningForAnswer, !isHoldingHotkey, let score = await VoiceID.shared.match(segment) {
            guard score >= VoiceID.threshold else {
                Log.info(String(format: "Ignored a voice that isn't yours (match %.2f)", score))
                return
            }
            Log.info(String(format: "Your voice (match %.2f)", score))
        }
        // Re-hear short leftovers ("Type in") together with what follows; longer phrases keep their own boundaries.
        let combined = mode == .command && !pendingAudio.isEmpty && pendingText.split(separator: " ").count <= 3
        let audio = combined ? pendingAudio + segment : segment
        guard !audio.isEmpty else { return }
        do {
            let text = try await recognize(audio)
            speechModel = .ready
            guard !text.isEmpty else { return }
            if settings.speechEngine != "apple" {
                let confidence = await Transcriber.shared.lastConfidence
                Log.info(String(format: "Heard (confidence %.2f, %.1fs): %@", confidence, Double(audio.count) / 16_000, text))
            }
            // Holding ⌥⌘ means it's you: every real phrase teaches Hark your voice a little more. So does the first
            // thing said right after tapping ⌥⌘ for hands-free, while Hark doesn't know your voice yet.
            let justTapped = handsFree && Date().timeIntervalSince(handsFreeStartedAt) < 8 && voiceSamples < 6
            if settings.voiceMatch, isHoldingHotkey || justTapped, mode == .command, !CommandParser.isNoise(text) {
                Task { [weak self] in
                    await VoiceID.shared.learn(segment)
                    let count = await VoiceID.shared.progress.samples
                    await MainActor.run { self?.voiceSamples = count }
                }
            }
            ingest(text, replacingPending: combined, audio: audio, segment: segment)
        } catch {
            speechModel = .unavailable(error.localizedDescription)
            fail("Speech recognition failed: \(error.localizedDescription)")
        }
    }

    // MARK: Voice match

    /// "Teach my voice": about 15 seconds of you talking about anything; nothing you say is acted on.
    public func learnVoice() {
        guard !learningVoice else { return }
        Task { try? await VoiceID.shared.prepare() }
        learningVoice = true
        learningStarted = Date()
        startHandsFree()
        transcript = "Talk for about 15 seconds — say anything. I'm learning your voice."
        reply = ""
        steps = []
    }

    private func learnVoiceSample(_ segment: [Float]) async {
        await VoiceID.shared.learn(segment)
        let count = await VoiceID.shared.progress.samples
        voiceSamples = count
        transcript = "Learning your voice… \(min(count, VoiceID.samplesNeeded + 2)) of \(VoiceID.samplesNeeded + 2)"
        if count >= VoiceID.samplesNeeded + 2 { endListening() }
    }

    /// Runs when the learning session's listening ends (enough samples, 40 s, or you tapped ⌥⌘).
    private func finishLearningVoice() {
        learningVoice = false
        transcript = ""
        reply = voiceSamples >= VoiceID.samplesNeeded
            ? "Got it — I know your voice now. In hands-free I'll ignore other people."
            : "I didn't hear enough. Try again and keep talking for a bit longer."
        settle()
    }

    public func forgetVoice() {
        Task {
            await VoiceID.shared.forget()
            voiceSamples = 0
        }
    }

    /// Loads the voice model and its saved samples (call at launch; ~25 MB, downloaded once).
    public func prepareVoiceMatch() async {
        voiceSamples = await VoiceID.shared.progress.samples
        guard settings.voiceMatch else { return }
        do { try await VoiceID.shared.prepare() } catch { Log.error("Voice match unavailable: \(error.localizedDescription)") }
    }

    /// Words that help recognition: your vocabulary plus well-known sites and the apps you have.
    var recognitionHints: [String] {
        settings.vocabulary + SpokenText.knownSites + ["Claude", "Claude Code", "Gemini", "ChatGPT", "Gmail", "Chrome", "Notes", "Slack", "WhatsApp"]
    }

    func recognize(_ audio: [Float]) async throws -> String {
        if settings.speechEngine == "apple", AppleTranscriber.authorized {
            AppleTranscriber.shared.locale = settings.speechLocale
            AppleTranscriber.shared.contextualStrings = recognitionHints
            return try await AppleTranscriber.shared.transcribe(audio)
        }
        return try await Transcriber.shared.transcribe(audio)
    }

    /// Transcribes every audio file in a folder with both engines and logs them side by side.
    public func benchmark(folder: URL) async {
        if !AppleTranscriber.authorized { _ = await AppleTranscriber.requestPermission() }
        AppleTranscriber.shared.locale = settings.speechLocale
        AppleTranscriber.shared.contextualStrings = recognitionHints
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["wav", "aiff", "m4a", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let samples = try? AudioFile.load(file) else { continue }
            var started = Date()
            let parakeet = (try? await Transcriber.shared.transcribe(samples)) ?? "(error)"
            let parakeetTime = Date().timeIntervalSince(started)
            started = Date()
            var apple: String
            do { apple = try await AppleTranscriber.shared.transcribe(samples) } catch { apple = "(error: \(error.localizedDescription))" }
            let appleTime = Date().timeIntervalSince(started)
            Log.info(String(format: "BENCH %@\n  parakeet (%.2fs): %@\n  apple    (%.2fs): %@", file.lastPathComponent, parakeetTime, parakeet, appleTime, apple))
        }
        Log.info("BENCH done")
    }

    // MARK: Understanding

    private func ingest(_ raw: String, replacingPending: Bool = false, audio: [Float] = [], segment: [Float] = []) {
        var text = Vocabulary.correct(SpokenText.normalize(raw, known: settings.vocabulary), terms: settings.vocabulary)
        if text != raw { Log.info("Heard “\(raw)” → “\(text)”") }
        // A sentence start held from just before ("Even though I" … "it misses words") belongs to this phrase — unless
        // it's old, or this phrase is a command on its own (then the fragment was someone else's).
        if let held = heldFragment, mode == .command {
            heldFragment = nil
            if Date().timeIntervalSince(held.at) < 8, !parser.parse(text).contains(where: { $0.command != nil }) {
                text = held.text + " " + text
            } else {
                Log.info("Ignored (not a request): “\(held.text)”")
            }
        }
        // Hands-free: a new request after the last one finished starts a fresh turn on the island.
        if handsFree, mode == .command, confirmation == nil, runner == nil, queue.isEmpty, pendingText.isEmpty, !committedHeard.isEmpty {
            finishHandsFreeTurn()
        }
        // Hark asked a question: this speech is the answer, acted on the moment it's clear.
        if confirmation != nil, mode == .command {
            answerHeard = answerHeard.isEmpty ? text : answerHeard + " " + text
            transcript = answerHeard
            if let approval = Self.approval(in: answerHeard) { answerConfirmation(approval, heard: answerHeard) }
            return
        }
        if replacingPending {
            // The new transcript already contains the waiting words, heard again with more context.
            pendingText = ""
            pendingHeard = text
        } else {
            pendingHeard = pendingHeard.isEmpty ? text : pendingHeard + " " + text
        }
        heardThisTurn = [committedHeard, pendingHeard].filter { !$0.isEmpty }.joined(separator: " ")
        transcript = heardThisTurn
        if mode == .dictation {
            dictation = heardThisTurn
            return
        }
        if confirmationPrompt != nil { return }
        if handsFree, text.lowercased().matches(#"^\W*(stop listening|that's all|that is all|i'm done|done listening|thanks hark|thank you hark)\W*$"#) {
            pendingHeard = ""
            endListening()
            return
        }
        // "search for best ramen" … "in Tokyo": a continuation refines the search that already ran.
        if let early = earlySearch, pendingText.isEmpty, let first = parser.parse(text).first, first.command == nil {
            let merged = early.query + " " + CommandParser.query(first.text)
            earlySearch = (merged, early.site)
            enqueue([.refineSearch(merged, early.site)], heard: text)
            commitHeard()
            let rest = parser.parse(text).dropFirst().map(\.text).joined(separator: ", ")
            if !rest.isEmpty { ingestRest(rest) }
            return
        }
        // A text field has focus: what the phrase is for is decided before anything is typed — words, punctuation,
        // keys, an edit, a stop, or a request for Hark (which goes on to the commands below).
        if pendingText.isEmpty, let ctx = fieldContext(), routeInField(text, ctx) { return }
        pendingText = Self.joinPhrases(pendingText, text)
        var (ready, remainder) = parser.streamingPlan(pendingText)
        // An in-app search can't be refined as you keep talking, so it waits until the phrase is finished.
        if remainder.isEmpty, let last = ready.last, case .searchHere = last, !searchGoesToGoogle(url: browser.lastTab?.url) {
            ready.removeLast()
            remainder = parser.parse(pendingText).last?.text ?? ""
        }
        pendingText = remainder
        // Keep the audio behind whatever is still waiting; if part of it already ran, keep only the newest phrase.
        pendingAudio = remainder.isEmpty ? [] : (ready.isEmpty ? audio : segment)
        if remainder.isEmpty {
            commitHeard()
        } else if !ready.isEmpty {
            // Part of what's waiting just ran: move it to the committed text, keep only the remainder pending.
            let done = pendingHeard.hasSuffix(remainder) ? String(pendingHeard.dropLast(remainder.count)) : pendingHeard
            committedHeard = [committedHeard, done.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".,")))]
                .filter { !$0.isEmpty }.joined(separator: " ")
            pendingHeard = remainder
        }
        if let last = ready.last {
            typingContinues = { switch last { case .typeText, .edit: return true; default: return false } }()
        }
        if let last = ready.last, case .webSearch(let query, let site) = last, remainder.isEmpty { earlySearch = (query, site) }
        else if let last = ready.last, case .searchHere(let query) = last, remainder.isEmpty { earlySearch = (query, .google) }
        else if !ready.isEmpty { earlySearch = nil }
        enqueue(ready, heard: text)
    }

    /// Logs the request that just finished and clears the island for the next one; listening carries on.
    private func finishHandsFreeTurn() {
        let heard = heardThisTurn.trimmingCharacters(in: .whitespaces)
        if !heard.isEmpty { log(heard: heard, result: turnResults.last ?? steps.last?.title ?? "", ok: turnOK) }
        committedHeard = ""
        pendingHeard = ""
        heardThisTurn = ""
        transcript = ""
        steps = []
        reply = ""
        turnResults = []
        turnOK = true
    }

    /// Writing mode: you typed something in the last 12 seconds, and that app is still in front. A command, a pause,
    /// or switching apps ends it — so later speech is never typed by mistake.
    private var writing: Bool {
        !written.isEmpty && Date().timeIntervalSince(lastWriteAt) < 120
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == typingApp
    }

    private func noteTyped() {
        typingContinues = true
        lastTypedAt = Date()
        typingApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// A pause is a natural boundary: end the earlier phrase with a period so the parser can split there
    /// when a new command starts, and merge when it doesn't ("search for the best. ramen in Tokyo").
    nonisolated public static func joinPhrases(_ earlier: String, _ next: String) -> String {
        guard !earlier.isEmpty else { return next }
        let ended = earlier.last.map { ".,!?;:".contains($0) } ?? false
        // "create a" … "new paragraph" is one thought; don't put a sentence break inside it.
        if !ended, CommandParser.endsMidThought(earlier) { return earlier + " " + next }
        return earlier + (ended ? " " : ". ") + next
    }

    /// The focused text field as the speech classifier sees it; nil when no text field has focus.
    private func fieldContext() -> SpeechIntent.Context? {
        guard TextEditor.isEditing() else { return nil }
        let focused = AX.value(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute).map { $0 as! AXUIElement } // swiftlint:disable:this force_cast
        let same = { (element: AXUIElement?) in element != nil && focused.map { CFEqual($0, element!) } == true }
        // Dictating: Hark typed into this very field in the last two minutes, or you said "start typing" here.
        let dictating = (writing && same(sessionElement)) || (Date().timeIntervalSince(primedAt) < 90 && same(primedElement))
        // What's before the caret: what Hark typed, or the field's own text when it can be read ("remove tomato" → is there a tomato?).
        let field = TextEditor.capture()
        let before = field.map { String(($0.text as NSString).substring(to: min($0.selection.location, ($0.text as NSString).length)).suffix(400)) } ?? ""
        return SpeechIntent.Context(kind: TextEditor.fieldKind(), dictating: dictating,
                                    recentText: dictating && !written.isEmpty ? String(written.suffix(300)) : before,
                                    before: field.flatMap(TextEditor.characterBeforeCaret),
                                    harkAsked: reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") && Date().timeIntervalSince(replyAt) < 90) { name in
            AppCatalog.shared.resolveExact(name) != nil || name.matches(#"^\S+\.(?:com|ai|in|org|io|net|dev|co|app)\b"#)
        }
    }

    /// Acts on speech heard in a text field. True when it's handled; false for a request, which the commands take.
    private func routeInField(_ text: String, _ ctx: SpeechIntent.Context, allowHold: Bool = true) -> Bool {
        let intent = SpeechIntent.classify(text, in: ctx, allowHold: allowHold)
        Log.info("In a \(ctx.kind.rawValue) field\(ctx.dictating ? " (dictating)" : ""): “\(text)” → \(intent.name)")
        switch intent {
        case .request:
            if SpeechIntent.isSend(text), let key = sendKey() {
                enqueue([.pressKeys(key)], heard: text)
                commitHeard()
                return true
            }
            return false
        case .stop:
            commitHeard()
            heldFragment = nil
            stopEverything()
            // "stop typing" means it: plain words aren't typed into a field for a minute, unless you say "type …".
            stoppedTypingAt = Date()
            primedAt = .distantPast
            primedElement = nil
        case .ignore:
            commitHeard()
        case .startDictation:
            stoppedTypingAt = .distantPast
            primeDictation()
            commitHeard()
        case .words where Date().timeIntervalSince(stoppedTypingAt) < 60 && CommandParser.typedPart(text) == nil:
            Log.info("Not typing “\(text)”: you said stop a moment ago (say “type …” or “start typing”)")
            commitHeard()
        case .hold:
            heldFragment = (text, Date())
        default:
            enqueue([.edit(text)], heard: text)
            commitHeard()
        }
        return true
    }

    /// The send key of the chat or mail app in front; nil when it isn't one Hark knows (then Claude sends it).
    private func sendKey() -> KeyCombo? {
        guard let app = AX.frontmostApp() else { return nil }
        let name = app.localizedName ?? ""
        let title = AX.focusedWindow(app).flatMap { AX.string($0, kAXTitleAttribute) } ?? ""
        if ["WhatsApp", "Slack", "Messages", "Telegram", "Discord", "Microsoft Teams", "Signal", "Messenger", "Terminal", "iTerm2", "Warp", "Ghostty"].contains(name) { return KeyCombo(key: "return") }
        if name == "Mail" { return KeyCombo(key: "d", command: true, shift: true) }
        guard Browser.all.contains(name) else { return nil }
        if title.range(of: #"\b(?:WhatsApp|Slack|Telegram|Discord|Messenger|Microsoft Teams|Google Chat)\b"#, options: .regularExpression) != nil { return KeyCombo(key: "return") }
        if title.range(of: #"\b(?:Gmail|Outlook)\b"#, options: .regularExpression) != nil { return KeyCombo(key: "return", command: true) }
        return nil
    }

    /// When you last said "stop typing" in a field: plain words wait for "type …" or "start typing" for a minute.
    private var stoppedTypingAt = Date.distantPast
    /// "start typing": for the next minute and a half, what you say in this field is dictation — orders to the reader too.
    private var primedAt = Date.distantPast
    private var primedElement: AXUIElement?

    private func primeDictation() {
        primedAt = Date()
        primedElement = TextEditor.capture()?.element
        addStep("Dictating", status: .done)
        Log.info("Dictating into this field: everything said here is typed")
    }

    /// A held sentence start nobody finished ("Even though I", then silence): taken as it is, never lost.
    private func flushHeld() {
        guard let held = heldFragment else { return }
        heldFragment = nil
        if let ctx = fieldContext() {
            if !routeInField(held.text, ctx, allowHold: false) { enqueue(parser.plan(held.text), heard: held.text) }
        } else {
            Log.info("Ignored (not a request): “\(held.text)”")
        }
    }

    private func commitHeard() {
        committedHeard = [committedHeard, pendingHeard].filter { !$0.isEmpty }.joined(separator: " ")
        pendingHeard = ""
        pendingAudio = []
    }

    /// Runs everything still waiting as if the key had been released (after a pause).
    private func flushPending() {
        let commands = parser.plan(pendingText)
        let heard = pendingText
        pendingText = ""
        commitHeard()
        enqueue(commands, heard: heard)
    }

    private func ingestRest(_ text: String) {
        pendingText = text
        let (ready, remainder) = parser.streamingPlan(pendingText)
        pendingText = remainder
        enqueue(ready, heard: text)
    }

    private func ingestFinal() {
        if learningVoice { return finishLearningVoice() }
        let heard = heardThisTurn.trimmingCharacters(in: .whitespaces)
        if mode == .dictation {
            guard !dictation.isEmpty else { return settle() }
            let text = Dictation.render(dictation)
            enqueue([.typeText(text)], heard: dictation)
            return
        }
        if confirmation != nil {
            // Nothing clear yet: keep the question up (buttons still work) instead of guessing.
            transcript = ""
            if phase == .transcribing { phase = .working }
            return
        }
        flushHeld()
        let commands = parser.plan(pendingText)
        pendingText = ""
        if commands.isEmpty && queue.isEmpty && runner == nil {
            if heard.isEmpty { reply = "I didn't catch that." }
            return settle()
        }
        if commands.isEmpty, runner != nil, phase == .transcribing { phase = .working }
        enqueue(commands, heard: heard)
        if runner == nil { settle() } else if phase == .transcribing { phase = .working }
    }

    /// Typed or automation-triggered requests take the same path as speech.
    public func handle(text: String) {
        Task { await EditorBrain.shared.prewarm() }
        turnFromUser = true
        heardBySpeech = false
        heardThisTurn = text
        transcript = text
        steps = []
        reply = ""
        turnResults = []
        turnOK = true
        if confirmation != nil {
            if let approval = Self.approval(in: text) { answerConfirmation(approval, heard: text) }
            return
        }
        if let ctx = fieldContext(), routeInField(text, ctx, allowHold: false) { return }
        let commands = parser.plan(text)
        enqueue(commands, heard: text)
    }

    // MARK: Doing

    private func enqueue(_ planned: [Command], heard: String) {
        // Coughs, "yeah"s, and other people's fragments never reach a model.
        let real = !heardBySpeech ? planned : planned.filter { command in
            switch command {
            case .agent(let text):
                guard writing ? CommandParser.isFiller(text) : CommandParser.isNoise(text) else { return true }
                if CommandParser.isFiller(text) {
                    Log.info("Ignored (not a request): “\(text)”")
                } else {
                    // Too short to act on alone, but maybe the start of a sentence: it joins what comes next.
                    heldFragment = (text, Date())
                    Log.info("Holding “\(text)” for what you say next")
                }
                return false
            default: return true
            }
        }
        // Speech heard in a text field was sorted before it got here (routeInField): words, edits and keys come as
        // .edit, requests as commands or .agent for Claude — nothing is turned into typing here.
        let commands = real
        guard !commands.isEmpty else {
            // Nothing real was said: don't leave the noise on the island in hands-free mode.
            if handsFree, runner == nil, queue.isEmpty { committedHeard = ""; pendingHeard = ""; heardThisTurn = ""; transcript = "" }
            return
        }
        if commands.contains(.stop) { stopEverything(); return }
        // Said it again because it's slow? It's already happening; doing it twice could delete twice.
        let fresh = commands.filter { command in
            guard command.isAgent else { return true }
            let same = { (other: Command) in other.title.lowercased() == command.title.lowercased() }
            if (running.map(same) ?? false) || queue.contains(where: { same($0.0) }) {
                Log.info("Already doing “\(command.title)”, not repeating it")
                return false
            }
            return true
        }
        guard !fresh.isEmpty else { return }
        for command in fresh {
            queue.append((command, heard))
            if command.isAgent { continue }
            steps.append(Step(title: command.title, status: .pending))
        }
        // Long hands-free sessions keep only the newest steps on the island.
        if steps.count > 8 { steps.removeFirst(steps.count - 8) }
        if runner == nil {
            runner = Task { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let (command, heard) = queue.removeFirst()
            if phase != .listening { phase = command.isAgent ? .thinking : .working }
            let step = steps.first { $0.title == command.title && $0.status == .pending }?.id
            mark(step, .running)
            if dryRun {
                dryRunLog.append((Double(consumedSamples) / 16_000, command.title))
                mark(step, .done)
                continue
            }
            running = command
            defer { running = nil }
            // Anything other than writing ends writing mode.
            switch command {
            case .edit, .typeText, .pressKeys, .scroll, .wait: break
            default: typingContinues = false
            }
            do {
                Log.info("Run: \(command.title)")
                let result = try await execute(command)
                Log.info("Done: \(command.title)\(result.map { " → \($0)" } ?? "")")
                mark(step, .done)
                if let result, !result.isEmpty { turnResults.append(result) }
                if !command.isAgent { claudeBrain.note(heard, did: command.title) }
            } catch is CancellationError {
                break
            } catch {
                mark(step, .failed)
                Log.error("Failed: \(command.title) — \(error.localizedDescription)")
                turnOK = false
                turnResults.append(error.localizedDescription)
                reply = error.localizedDescription
            }
        }
        runner = nil
        if phase != .listening {
            settle()
        } else if handsFree, somethingToShow {
            tick()
        }
    }

    /// Steps are cleared or trimmed while a command runs (the next phrase, a new turn), so they're found by id, never by index.
    private func mark(_ step: UUID?, _ status: Step.Status) {
        if let step, let i = steps.firstIndex(where: { $0.id == step }) { steps[i].status = status }
    }

    private var somethingToShow: Bool {
        !reply.isEmpty || steps.contains { $0.status == .done || $0.status == .failed }
    }

    private func settle() {
        let heard = heardThisTurn.trimmingCharacters(in: .whitespaces)
        if !heard.isEmpty, phase != .listening {
            log(heard: heard, result: turnResults.last ?? steps.last?.title ?? "", ok: turnOK)
            heardThisTurn = ""
        }
        guard phase != .listening else { return }
        phase = .idle
        if somethingToShow { tick() }
        scheduleHide()
    }

    /// The island stays up long enough to read what it says (longer text, longer time), and never hides
    /// while the pointer is over it. `sticky` messages (reminders, alerts) stay until dismissed.
    private func scheduleHide(sticky: Bool = false) {
        hideWork?.cancel()
        guard !sticky else { hideWork = nil; return }
        let words = (transcript + " " + reply).split(whereSeparator: \.isWhitespace).count
        let delay = min(60, 2.6 + Double(words) * 0.3)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase != .listening, self.runner == nil, self.confirmation == nil else { return }
            if self.pointerOverIsland() { self.scheduleHide(); return }
            self.dismiss()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// True while the pointer is over the island, so text being read or scrolled stays put. Set by the app.
    public var pointerOverIsland: () -> Bool = { false }

    /// Closes the island (its × button). Doesn't stop work in progress.
    public func dismiss() {
        guard phase != .listening, runner == nil, confirmation == nil else { return }
        hideWork?.cancel()
        phase = .idle
        steps = []
        transcript = ""
        reply = ""
    }

    /// Cancels whatever Hark is doing (the island's Stop button, "stop", or ⎋).
    /// Listening (held or hands-free) carries on: "stop" stops actions, not the microphone.
    public func stopEverything() {
        queue.removeAll()
        runner?.cancel()
        runner = nil
        endSession()  // a correction under way finds the text changed and drops its answer
        if let confirmation { confirmation.resume(returning: false) }
        confirmation = nil
        confirmationPrompt = nil
        steps = []
        reply = "Stopped."
        if phase != .listening { phase = .idle; scheduleHide() }
    }

    /// Executes one command; returns words worth saying.
    private func execute(_ command: Command) async throws -> String? {
        try Task.checkCancellation()
        // Anything other than writing ends the dictation. Return, "send it", another app: the last correction lands first.
        // Other keys (undo, select all…): the pending correction is dropped, so it can't land on top of them.
        switch command {
        case .edit, .typeText: break
        case .pressKeys(let combo) where combo.key != "return":
            if !written.isEmpty { await abandonPass(); endSession() }
        default:
            if !written.isEmpty { await settleWriting(); endSession() }
        }
        switch command {
        case .openApp(let name):
            guard let app = AppCatalog.shared.resolve(name) else { throw HarkError("I couldn't find an app called \(name).") }
            if Browser.all.contains(app.name) {
                settings.preferredBrowser = app.name
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let running = try await NSWorkspace.shared.openApplication(at: app.url, configuration: config)
            if Browser.all.contains(app.name) { try await browser.activate() }
            // The next command (⌘N, typing) must land in this app, so wait until it's really in front.
            for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier {
                running.activate()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            return brief(command)
        case .quitApp(let name):
            guard let app = AppCatalog.shared.runningApplication(named: name) else { return "\(name) isn't open." }
            app.terminate()
            return brief(command)
        case .openURL(let url):
            if url.isFileURL { NSWorkspace.shared.open(url) } else { try await browser.open(url) }
            return brief(command)
        case .webSearch(let query, let site):
            try await browser.open(site.url(for: query))
            return brief(command)
        case .searchHere(let query):
            try await searchHere(query)
            return brief(command)
        case .refineSearch(let query, let site):
            try await browser.open(site.url(for: query), replaceCurrent: true)
            return nil
        case .searchSelection(let site):
            guard let text = await selectionText(), !text.isEmpty else { throw HarkError("Nothing is selected.") }
            try await browser.open(site.url(for: String(text.prefix(300))), forceNewTab: true)
            return "Searching for \(text.prefix(60))"
        case .browser(let action):
            try await browser.perform(action)
            return brief(command)
        case .typeText(let text):
            guard !text.isEmpty else { return nil }  // "start typing": just a cue
            // Insert through Accessibility right away (works mid-speech); paste after release as a fallback.
            if AX.insertText(text) { Log.info("Typed via Accessibility"); return nil }
            await waitForKeysReleased()
            try await Keyboard.type(text)
            Log.info("Typed via paste (after key release)")
            return nil
        case .pressKeys(let combo):
            // Pasting into a text field goes in like typed text: spaced right, and no need to wait for ⌥⌘.
            if combo == KeyCombo(key: "v", command: true), TextEditor.isEditing() {
                addStep(try await textEditor.apply(["op": "paste"], app: "", url: nil), status: .done)
                return nil
            }
            await waitForKeysReleased()
            try Keyboard.press(combo)
            return nil
        case .scroll(let direction, let amount):
            // "Go to the end" in a text field means the cursor, not the page.
            if amount == .large, [.top, .bottom].contains(direction), TextEditor.isEditing() {
                let label = try await textEditor.apply(["op": "caret", "to": direction == .top ? "start" : "end"], app: "", url: nil)
                addStep(label, status: .done)
                return nil
            }
            pointMouseAtFrontWindow()
            Keyboard.scroll(direction, amount)
            return nil
        case .click(let target):
            return try await click(target)
        case .system(let action, let value):
            let said = try await SystemControl.perform(action, value: value) { await self.waitForKeysReleased() }
            return said
        case .window(let action):
            if !AX.setWindow(action) {
                await waitForKeysReleased()
                let keys: [WindowAction: KeyCombo] = [
                    .minimize: KeyCombo(key: "m", command: true), .fullscreen: KeyCombo(key: "f", command: true, control: true),
                    .close: KeyCombo(key: "w", command: true), .hide: KeyCombo(key: "h", command: true),
                ]
                if let combo = keys[action] { try Keyboard.press(combo) }
            }
            return nil
        case .wait(let seconds):
            try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 600)) * 1_000_000_000))
            return nil
        case .tellTime:
            let f = DateFormatter()
            f.timeStyle = .short
            let text = "It's \(f.string(from: Date()))."
            reply = text
            return text
        case .tellDate:
            let f = DateFormatter()
            f.dateFormat = "EEEE, MMMM d"
            let text = "It's \(f.string(from: Date()))."
            reply = text
            return text
        case .schedule(let after, let at, let task, let reminder):
            let date = after.map { Date().addingTimeInterval($0) } ?? at.map { Scheduler.nextOccurrence(of: $0) } ?? Date()
            scheduler.add(Automation(trigger: .once(date), task: task, reminder: reminder, createdBy: "you"))
            let f = DateFormatter()
            f.timeStyle = .short
            let text = reminder ? "Okay, I'll remind you at \(f.string(from: date))." : "Okay, I'll do that at \(f.string(from: date))."
            reply = text
            return text
        case .recurring(let when, let task):
            guard let trigger = Scheduler.trigger(from: when) else { throw HarkError("I couldn't understand “\(when)”.") }
            let automation = scheduler.add(Automation(trigger: trigger, task: task, reminder: false, createdBy: "you"))
            let text = "Okay — \(automation.summary.components(separatedBy: " — ").last ?? when), I'll \(task.lowercased())."
            reply = text
            return text
        case .claude(let prompt):
            return try await ClaudeBridge.send(prompt) { await self.waitForKeysReleased() }
        case .downloadCurrent:
            if let tab = try? await browser.currentTab(), let url = URL(string: tab.url), Downloader.isDirectFile(url) {
                let file = try await Downloader.download(url)
                return "Saved \(file.lastPathComponent) to Downloads"
            }
            return try await runAgent("Download the main file from the current page: read the screen, then click its download button.")
        case .openResult(let n):
            if let front = NSWorkspace.shared.frontmostApplication?.localizedName, !Browser.all.contains(front) {
                try await browser.activate()
            }
            for attempt in 0..<4 {
                if AX.openSearchResult(n) { return brief(command) }
                try await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
            }
            throw HarkError("I couldn't find result \(n) on this page.")
        case .say(let text):
            reply = text
            return text
        case .watch(let spec):
            let watch = await makeWatch(spec)
            scheduler.add(Automation(trigger: .screenWatch(watch), task: spec.action, reminder: false, createdBy: "you"))
            if let rect = watch.rect { flash(rect, .confirm) }
            let text = "Watching. When \(watch.label), I'll \(spec.action.lowercased())."
            reply = text
            return text
        case .closeCurrent:
            if let front = NSWorkspace.shared.frontmostApplication?.localizedName, Browser.all.contains(front) {
                try await browser.perform(.closeTab)
            } else if !AX.setWindow(.close) {
                await waitForKeysReleased()
                try Keyboard.press(KeyCombo(key: "w", command: true))
            }
            return brief(command)
        case .stopWatching:
            let watchers = scheduler.automations.filter {
                if case .screenWatch = $0.trigger { return true }
                if case .textAppears = $0.trigger { return true }
                return false
            }
            watchers.forEach { scheduler.remove($0.id) }
            let text = watchers.isEmpty ? "I wasn't watching anything." : "Stopped \(watchers.count) watcher\(watchers.count == 1 ? "" : "s")."
            reply = text
            return text
        case .stop:
            stopEverything()
            return nil
        case .edit(let request):
            return try await runEditor(request)
        case .agent(let text):
            return try await runAgent(text)
        }
    }

    // MARK: Writing and editing

    /// The writing model plans exact steps from the field's real text (no screenshot); Hark carries them out.
    /// Anything it can't do as a text edit goes to Claude with the screen.
    private func runEditor(_ request: String) async throws -> String? {
        let started = Date()
        // What the phrase is, decided again now that what came before it is done (SpeechIntent).
        let ctx = fieldContext() ?? SpeechIntent.Context(kind: .area, dictating: false)
        switch SpeechIntent.classify(request, in: ctx, allowHold: false) {
        case .words(let text, let then):
            try await write(text, heard: request)
            if let then { enqueue(parser.plan(then), heard: then) }
            return nil
        case .punctuation(let text):
            try await write(text, heard: request)
            return nil
        case .keys(let combo, let times):
            for _ in 0..<times { _ = try await execute(.pressKeys(combo)) }
            return nil
        case .stop:
            stopEverything()
            return nil
        case .ignore, .hold:
            return nil
        case .startDictation:
            primeDictation()
            return nil
        case .request:
            // Hark's own commands when it has them; anything else is Claude's.
            let commands = parser.plan(request)
            let instant = commands.allSatisfy { command in
                if command.isAgent { return false }
                if case .edit = command { return false }
                return true
            }
            guard !commands.isEmpty, instant else {
                return try await runAgent(request)
            }
            var said: String?
            for command in commands { said = try await execute(command) ?? said }
            return said
        case .edit:
            // About what was just dictated: "scratch that" takes back the last words exactly; other corrections
            // ("put that in brackets", "I meant sixty") go to the writing pass, which rewrites the dictated text.
            if !written.isEmpty, SpeechIntent.takesBackLast(request), try await takeBackLast(request) { return nil }
            if !written.isEmpty, writing, SpeechIntent.rewritesDictation(request) {
                heard.append(request)
                instructed = true
                noteTyped()
                addStep("“\(TextEditor.short(request))”", status: .done)
                Log.info("For the writing pass: “\(request)”")
                schedulePass()
                return nil
            }
        case .askFirst:
            break
        }
        // Edit steps (and anything the words alone couldn't decide): the writing model plans them from the field's text.
        await settleWriting()  // so the model reads the corrected text
        let field = TextEditor.capture()
        // "select X" outside any text field means picking it on screen.
        if field == nil, let m = request.firstMatch(#"^(?i:select|highlight)(?i: the)?\s+(.+?)[.!]?$"#) {
            return try await click(m[1])
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let tab = Browser.all.contains(app) ? (try? await browser.currentTab()) : nil
        var lines = ["[App] \(app)" + (tab.map { " — \($0.title) — \($0.url)" } ?? "")]
        lines.append(field?.describe() ?? "[Field] none readable\n[Text] unavailable (insert, format and key still work)")
        if !recentEdits.isEmpty { lines.append("[Recent] " + recentEdits.suffix(4).joined(separator: " · ")) }
        lines.append("[Said] \(request)")
        let answer: String
        do {
            answer = try await EditorBrain.shared.ask(lines.joined(separator: "\n"))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.error("Writing model: \(error.localizedDescription)")
            return try await runAgent(request)
        }
        let (ops, say) = EditorBrain.plan(from: answer)
        Log.info("Writing plan for “\(request)”: \(answer.replacingOccurrences(of: "\n", with: " ").prefix(300))")
        // Edit steps change the text under the session: the next words start a new one.
        if !ops.isEmpty { endSession() }
        if ops.contains(where: { ($0["op"] as? String)?.lowercased() == "agent" }) { return try await runAgent(request) }
        var did: [String] = []
        for op in ops {
            try Task.checkCancellation()
            let name = (op["op"] as? String ?? "").lowercased()
            let label: String
            do {
                if name == "search" {
                    label = try await search(op["query"] as? String ?? "", where: op["where"] as? String ?? "here")
                } else {
                    label = try await textEditor.apply(op, app: app, url: tab?.url)
                }
            } catch EditError.needsScreen(let why) {
                Log.info("Writing step needs the screen (\(why)); asking Claude")
                return try await runAgent(request)
            }
            if !label.isEmpty { addStep(label, status: .done); did.append(label) }
        }
        if ops.contains(where: { ["insert", "type", "write", "paste"].contains(($0["op"] as? String ?? "").lowercased()) }) { noteTyped() }
        let summary = did.isEmpty ? (say.isEmpty ? "Nothing to change." : say) : did.joined(separator: " · ")
        noteEdit(request, did: summary)
        Log.info(String(format: "Edited in %.2fs: %@", Date().timeIntervalSince(started), summary))
        if !say.isEmpty { reply = say }
        return say.isEmpty ? nil : say
    }

    /// Remembers an edit for the writing model ("undo that") and for Claude.
    private func noteEdit(_ request: String, did: String) {
        recentEdits.append("“\(request)” → \(did)")
        if recentEdits.count > 8 { recentEdits.removeFirst(recentEdits.count - 8) }
        claudeBrain.note(request, did: did)
    }

    // MARK: Writing session

    /// While you write, Hark types what you say at once, and a background pass then turns your speech into the text you
    /// meant — mishearings and spelled-out names fixed, "put that in brackets" or "scratch that" carried out — and
    /// swaps in only what differs. `written` is exactly what Hark has typed this session, right before the caret;
    /// `checked` is the part a pass has already made right; `heard` is your speech since then, raw. If you keep
    /// talking while a pass runs, its answer is dropped and the next pass covers everything.
    private var written = ""
    /// The text field this session types into: never any other, even one that ends with the same words.
    private var sessionElement: AXUIElement?
    private var checked = ""
    private var heard: [String] = []
    private var sessionVersion = 0
    private var pass: Task<Void, Never>?
    private var lastWriteAt = Date.distantPast
    /// Typing and corrections take turns: two pastes at once could swap their clipboard contents.
    private var typingBusy = false
    /// Each phrase as typed, in order, while no correction has changed them: "scratch that" takes back the last exactly.
    private var pieces: [String] = []
    /// An instruction about the dictated text is waiting for the pass ("put that in brackets"): it may change older text.
    private var instructed = false { didSet { if instructed { instructedAt = Date() } } }
    private var instructedAt = Date.distantPast

    /// Types `words` now and has the next pass look at them.
    private func write(_ words: String, heard phrase: String) async throws {
        let started = Date()
        await lockTyping()
        defer { typingBusy = false }
        // Picking up where this session left off? (Right after a paste a web editor may not show it yet.)
        if !written.isEmpty, Date().timeIntervalSince(lastWriteAt) > 1, sessionField() == nil {
            endSession("Starting a new writing session: the text around what I typed has changed (\(Self.beforeCaret(TextEditor.capture())))")
        }
        if written.isEmpty { sessionElement = TextEditor.capture()?.element }
        let typed = try await textEditor.insert(words)
        written += typed
        pieces.append(typed)
        heard.append(phrase)
        lastWriteAt = Date()
        noteTyped()
        addStep("Type “\(TextEditor.short(words))”", status: .done)
        noteEdit(phrase, did: "Type “\(TextEditor.short(words))”")
        Log.info(String(format: "Typed instantly in %.0f ms: “%@”", Date().timeIntervalSince(started) * 1000, words))
        schedulePass()
    }

    private func schedulePass() {
        sessionVersion += 1
        guard pass == nil else { return }  // the running pass sees the new speech and goes again
        pass = Task { [weak self] in
            while let self = self, !Task.isCancelled, !self.heard.isEmpty {
                let version = self.sessionVersion
                await self.runPass()
                if self.sessionVersion == version { break }
            }
            self?.pass = nil
        }
    }

    private func runPass() async {
        let consumed = heard.count, seen = written
        let started = Date()
        guard let field = await sessionFieldSettled(), let range = sessionRange(in: field) else {
            return endSession("Not correcting: the text around what I typed has changed (\(Self.beforeCaret(TextEditor.capture())))")
        }
        let ns = field.text as NSString
        let from = max(0, range.location - 300)
        let lead = String(written.prefix { $0.isWhitespace })
        let fresh = String(written.dropFirst(checked.count))
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let lines = ["[App] \(app)", "[Before] \(ns.substring(with: NSRange(location: from, length: range.location - from)))",
                     "[Written] \(checked.dropFirst(min(lead.count, checked.count)))",
                     "[Just typed] \(checked.isEmpty ? String(fresh.dropFirst(lead.count)) : fresh)",
                     "[Heard]\n" + heard.suffix(12).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")]
        guard let answer = try? await EditorBrain.shared.ask(lines.joined(separator: "\n")), !Task.isCancelled else { return }
        // Words typed meanwhile follow the part this answer is about and stay as they are; anything else (a take-back,
        // undo, a new session) makes the answer stale.
        guard !seen.isEmpty, written.hasPrefix(seen) else { return Log.info("Writing pass: the text changed meanwhile; going again") }
        let (text, _) = EditorBrain.session(from: answer)
        let seconds = Date().timeIntervalSince(started)
        var failed = false
        var covered = seen
        if let text {
            let intended = lead + text.drop { $0 == " " }
            // With no instruction in what was heard, a correction only touches the newest words and never removes a phrase.
            let settled = String(checked.reversed().drop { ".,;:!? \n".contains($0) }.reversed())
            let drift = !instructed && (!TextEditor.sameText(String(intended.prefix(settled.count)), settled)
                || intended.trimmingCharacters(in: .whitespacesAndNewlines).count < seen.trimmingCharacters(in: .whitespacesAndNewlines).count / 2)
            if drift {
                Log.info("Writing pass: wanted “\(TextEditor.short(intended))” — more than fixing the newest words; left it")
            } else if intended != seen {
                await lockTyping()
                guard written.hasPrefix(seen) else {
                    typingBusy = false
                    return Log.info("Writing pass: the text changed meanwhile; going again")
                }
                let whole = intended + written.dropFirst(seen.count)
                let done = await applySession(whole)
                typingBusy = false
                if done {
                    Log.info(String(format: "Writing pass in %.2fs: “%@” → “%@”", seconds, TextEditor.short(seen), TextEditor.short(intended)))
                    written = whole
                    covered = intended
                    pieces = []  // the phrases are rewritten: "scratch that" now goes to the writing model
                    addStep("Fixed → “\(TextEditor.short(intended.trimmingCharacters(in: .whitespacesAndNewlines)))”", status: .done)
                    noteEdit(heard.joined(separator: " "), did: "Corrected to “\(intended)”")
                } else {
                    failed = true
                    Log.info("Writing pass: should be “\(TextEditor.short(intended))”, but I couldn't change it safely; left it")
                }
            } else {
                Log.info(String(format: "Writing pass in %.2fs: right as typed", seconds))
            }
        }
        if failed {
            endSession()
        } else {
            checked = covered
            heard.removeFirst(min(consumed, heard.count))
            // An instruction said while this pass ran is still waiting for the next one.
            if instructedAt < started { instructed = false }
        }
    }

    /// Swaps in the text you meant, changing it only from the first difference on.
    private func applySession(_ intended: String) async -> Bool {
        guard let field = await sessionFieldSettled(), let range = sessionRange(in: field) else { return false }
        let old = Array(written), new = Array(intended)
        var keep = 0
        while keep < old.count, keep < new.count, old[keep] == new[keep] { keep += 1 }
        let oldTail = String(old[keep...]), newTail = String(new[keep...])
        guard TextEditor.isWebField() else {
            let offset = (String(old[..<keep]) as NSString).length
            let part = NSRange(location: range.location + offset, length: (oldTail as NSString).length)
            return (try? await textEditor.change(part, in: field, to: newTail)) == true
        }
        // Web editors: by keys from the caret, checked against what Hark typed, so only a reasonable way back.
        guard oldTail.count <= 240 else {
            Log.info("Writing pass: the fix starts \(oldTail.count) characters back; too far to retype safely")
            return false
        }
        guard (try? await textEditor.retypeBeforeCaret(oldTail.count, expecting: oldTail, with: newTail)) == true else { return false }
        for attempt in 0..<12 {
            if let now = TextEditor.capture(), TextEditor.sessionRange(intended, in: now.text, selection: now.selection, web: true) != nil { return true }
            if attempt < 11 { try? await Task.sleep(nanoseconds: 80_000_000) }
        }
        try? await textEditor.collapseSelection()  // it didn't take: leave your text as it was, nothing selected
        return false
    }

    /// Where this session's text sits in `field`, if it's still right before the caret.
    private func sessionRange(in field: TextField) -> NSRange? {
        guard let sessionElement, CFEqual(field.element, sessionElement) else { return nil }
        return TextEditor.sessionRange(written, in: field.text, selection: field.selection, web: TextEditor.isWebField())
    }

    private func sessionField() -> TextField? {
        guard let field = TextEditor.capture(), sessionRange(in: field) != nil else { return nil }
        return field
    }

    /// The field once it shows this session's text before the caret: a web editor reports a paste a moment late.
    private func sessionFieldSettled() async -> TextField? {
        for attempt in 0..<8 {
            if let field = sessionField() { return field }
            if attempt < 7 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        return nil
    }

    private func lockTyping() async {
        while typingBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
        typingBusy = true
    }

    private func endSession(_ reason: String? = nil) {
        if let reason, !written.isEmpty { Log.info(reason) }
        written = ""
        pieces = []
        instructed = false
        sessionElement = nil
        checked = ""
        heard = []
        sessionVersion += 1  // a pass in flight drops its answer
    }

    /// Drops the pending correction (undo, select all…): it must not land on top of what you asked for. Waits for
    /// keystrokes already under way to finish.
    private func abandonPass() async {
        // Not cancelled: that would stop the writing model mid-answer, and the next request would wait for a fresh one.
        sessionVersion += 1
        for _ in 0..<100 where typingBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// "scratch that": the last words Hark typed come out, exactly — no model. False when that can't be done safely
    /// (a correction has rewritten them, or the caret moved); the writing model then handles it.
    private func takeBackLast(_ request: String) async throws -> Bool {
        await abandonPass()
        guard let last = pieces.last, !last.isEmpty, written.hasSuffix(last) else { return false }
        await lockTyping()
        defer { typingBusy = false }
        let length = (last as NSString).length
        var done = false
        if let field = await sessionFieldSettled(), let range = sessionRange(in: field) {
            if TextEditor.isWebField() {
                done = (try? await textEditor.retypeBeforeCaret(last.count, expecting: last, with: "")) == true
            } else {
                let part = NSRange(location: range.location + range.length - length, length: length)
                done = (try? await textEditor.change(part, in: field, to: "")) == true
            }
        } else if Date().timeIntervalSince(lastWriteAt) < 60, TextEditor.fieldKind() == .area,
                  TextEditor.capture().map({ CFEqual($0.element, sessionElement ?? $0.element) }) ?? true {
            // A field that doesn't show its text (a spreadsheet cell, a code editor): Hark just typed these characters there.
            done = (try? await textEditor.retypeBeforeCaret(last.count, expecting: nil, with: "")) == true
        }
        guard done else { return false }
        pieces.removeLast()
        written = String(written.dropLast(last.count))
        checked = String(checked.prefix(written.count))
        heard = []
        addStep("Removed “\(TextEditor.short(last.trimmingCharacters(in: .whitespaces)))”", status: .done)
        noteEdit(request, did: "Removed “\(last)”")
        Log.info("Took back “\(last.trimmingCharacters(in: .whitespaces))”")
        if written.isEmpty { endSession() }
        return true
    }

    /// Lets the writing pass finish (briefly) before anything reads the field or takes the text away — a model reading
    /// it, Return, another app — so a correction never lands after the message is sent.
    private func settleWriting() async {
        for _ in 0..<35 where pass != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// hark://edit: runs raw edit steps (TextEditor ops, plus "wait" with "ms" and "paste_text" with "text", which types
    /// by pasting) and logs the field after each, to work out how an editor behaves.
    public func debugEdit(_ json: String) async {
        guard let ops = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            return Log.error("hark://edit: ops must be a JSON array of steps")
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        // "only_in": every step first checks that the focused field has this label, and stops otherwise.
        let only = ops.first { $0["op"] as? String == "only_in" }?["label"] as? String
        for op in ops where op["op"] as? String != "only_in" {
            let name = op["op"] as? String ?? ""
            if let only, TextEditor.capture()?.label != only {
                return Log.error("hark://edit: stopped before \(name): the focused field isn't “\(only)”")
            }
            var label = ""
            do {
                switch name {
                case "retype":
                    try await textEditor.retypeBeforeCaret(op["count"] as? Int ?? 0, with: op["text"] as? String ?? "")
                    label = "retyped"
                case "collapse": try await textEditor.collapseSelection(); label = "collapsed"
                case "select_back":
                    for _ in 0..<(op["count"] as? Int ?? 0) { try Keyboard.press(KeyCombo(key: "left", shift: true)) }
                    label = "selected back"
                case "wait": try await Task.sleep(nanoseconds: UInt64(op["ms"] as? Int ?? 300) * 1_000_000)
                case "paste_text": try await Keyboard.type(op["text"] as? String ?? ""); label = "pasted"
                case "key_text": Keyboard.typeKeys(op["text"] as? String ?? ""); label = "typed as keys"
                case "shift_tap": Keyboard.tapShift(); label = "tapped shift"
                default: label = try await textEditor.apply(op, app: app, url: nil)
                }
            } catch {
                label = "failed: \(error.localizedDescription)"
            }
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            Log.info("Edit step \(name) \(label) → [\(front)] \(Self.beforeCaret(TextEditor.capture()))")
        }
    }

    /// For the log: where the caret is and the text just before it.
    private static func beforeCaret(_ field: TextField?) -> String {
        guard let field else { return "no readable field" }
        let ns = field.text as NSString, caret = min(field.selection.location, ns.length)
        let start = max(0, caret - 40)
        let before = ns.substring(with: NSRange(location: start, length: caret - start)).replacingOccurrences(of: "\n", with: "↵")
        return "caret \(caret)+\(field.selection.length) of \(ns.length), before it “\(before)”"
    }


    /// Search where the writing model said: this site or app, the web, this page, or a named site.
    private func search(_ query: String, where place: String) async throws -> String {
        guard !query.isEmpty else { return "" }
        switch place.lowercased() {
        case "here", "":
            try await searchHere(query)
        case "web", "google":
            try await browser.open(SearchSite.google.url(for: query))
        case "page", "find", "this page":
            await waitForKeysReleased()
            try Keyboard.press(KeyCombo(key: "f", command: true))
            try await Task.sleep(nanoseconds: 250_000_000)
            if !AX.insertText(query) { try await Keyboard.type(query) }
        case let site:
            if let known = SearchSite(rawValue: site) {
                try await browser.open(known.url(for: query))
            } else if let url = await SiteSearch.shared.url(host: site.contains(".") ? site : site + ".com", query: query) {
                try await browser.open(url)
            } else {
                try await browser.open(SearchSite.google.url(for: "\(query) \(site)"))
            }
        }
        return "Search “\(TextEditor.short(query))”"
    }

    private func brief(_ command: Command) -> String? {
        command.spoken
    }

    private func runAgent(_ text: String) async throws -> String {
        await settleWriting()
        // Keys still held: keep listening; the island shows the steps as they happen.
        if phase != .listening { phase = .thinking }
        brainModel = .loading
        claudeBrain.model = settings.claudeModel
        pointing = nil
        // The pointer's area only matters when the request is about it ("this", "here", "this section"…).
        if turnFromUser, text.range(of: RegionPicker.pointingWords, options: [.regularExpression, .caseInsensitive]) != nil {
            let point = pointerForHere
            let (app, rect) = RegionPicker.region(at: point)
            pointing = (point, app, rect)
            flash(rect, .looking)
        }
        defer { pointing = nil }
        // What worked here before for something similar: Claude starts from it instead of exploring.
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let site = Browser.all.contains(app) ? ((try? await browser.currentTab()).flatMap { URL(string: $0.url)?.host }?
            .replacingOccurrences(of: "www.", with: "") ?? "") : ""
        let learned = lessonBook.relevant(to: text, app: app, site: site)
        let started = Date()
        // The last action and the last look carry over from earlier requests, so "create a memory of it" can count the
        // check that ended the task it follows.
        agentLessons = learned
        effort = RunEffort()
        let lessonsBefore = lessonBook.lessons.count
        var context = await currentContext()
        if !learned.isEmpty {
            context += "\n[Learned] How similar tasks were done here before (verified):\n"
                + learned.map { "\($0.id) · \($0.task)\($0.site.isEmpty ? "" : " on \($0.site)") (\($0.app)): \($0.how)" }.joined(separator: "\n")
            Log.info("Using what I learned: " + learned.map { "\($0.id) \($0.task)" }.joined(separator: "; "))
        }
        let answer: String
        do {
            answer = try await claudeBrain.run(text, context: context)
            brainModel = .ready
        } catch {
            brainModel = brainAvailable ? .ready : .unavailable("Claude Code not installed")
            throw error
        }
        // Lessons Claude was given and didn't drop: if it confirmed the result on screen, they worked again.
        let checked = agentLookedAt > agentActedAt && agentActedAt > started
        if checked { agentLessons.forEach { lessonBook.worked($0.id) } }
        // Worth remembering only when something had to be worked out: a step failed, was redone or backed out of, or it
        // took a lot of looking around. The result must be checked on screen, and no lesson may already cover it. Hark
        // asks (Claude doesn't reliably think to), after the answer is showing, in the same conversation; Claude decides,
        // and a task that was long but straightforward isn't a lesson.
        if checked, effort.worthAsking, lessonBook.lessons.count == lessonsBefore, agentLessons.isEmpty {
            reply = answer
            Log.info("Asking Claude whether it learned something (\(effort.summary))")
            try? await claudeBrain.followUp("""
            [Hark] That took some working out. Only if you found out something non-obvious that would save time next time \
            (a hidden menu, a specific button or shortcut, an order that matters, a way that works where the obvious one \
            didn't) and you saw it work on screen, call remember_how with it in one or two short sentences, including what \
            didn't work. A task that was just long but straightforward isn't one. Otherwise reply only "no".
            """)
        } else {
            if checked, lessonBook.lessons.count == lessonsBefore { Log.info("Nothing to learn here (\(effort.summary))") }
            await claudeBrain.finish()
        }
        reply = answer
        return answer
    }

    private func currentContext() async -> String {
        var lines: [String] = []
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        lines.append("Now: \(f.string(from: Date()))")
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName { lines.append("Front app: \(app)") }
        if Browser.all.contains(NSWorkspace.shared.frontmostApplication?.localizedName ?? ""), let tab = try? await browser.currentTab() {
            lines.append("Browser page: \(tab.title) — \(tab.url)")
        }
        if !turnResults.isEmpty { lines.append("Already done this turn: " + turnResults.joined(separator: "; ")) }
        if !settings.vocabulary.isEmpty { lines.append("Names/addresses the user uses: " + settings.vocabulary.joined(separator: ", ")) }
        if let pointed = pointingContext() { lines.append(pointed) }
        lines.append("[Screen]\n" + (await screenSummary()))
        return lines.joined(separator: "\n")
    }

    /// The pointer that "here" refers to: live while listening, otherwise where it was when the keys were released.
    private var pointerForHere: CGPoint {
        phase == .listening ? RegionPicker.mouse : (pointAtRelease ?? RegionPicker.mouse)
    }

    /// What the user is pointing at, in words: where the pointer is, the text in the outlined area, and any selection.
    private func pointingContext() -> String? {
        guard let pointing else { return nil }
        var lines = ["[Pointing] The mouse pointer is at (\(Int(pointing.point.x)), \(Int(pointing.point.y)))"
            + (pointing.app.map { " over \($0)" } ?? "")
            + ". The area around it is the red box on the screenshot, and the second image shows it close up."
            + " \"This\", \"here\", \"this section\", \"around my cursor\", or \"what I'm pointing at / highlighting\" mean this area."]
        let text = AX.text(app: pointing.app, region: pointing.rect, limit: 1500)
        if !text.isEmpty { lines.append("Text in that area:\n" + text) }
        if let selected = AX.selectedText(), !selected.isEmpty { lines.append("Selected text: " + String(selected.prefix(1500))) }
        return lines.joined(separator: "\n")
    }

    /// Screenshots for Claude: the whole screen with the pointed-at area boxed in red, plus that area close up.
    /// Needs Screen Recording; asks once if it's missing.
    func screenImages() async -> [ScreenImage] {
        guard ScreenText.hasPermission else {
            if !askedForScreen { askedForScreen = true; ScreenText.requestPermission() }
            return []
        }
        let pointing = self.pointing
        guard let (image, bounds) = try? await ScreenText.captureDisplay(containing: pointing?.point) else { return [] }
        let pixels = CGFloat(image.width) / max(bounds.width, 1)
        // The pointed-at area in this image's pixels (top-left origin), when it's on this display.
        let area = pointing.flatMap { pointing -> CGRect? in
            let visible = pointing.rect.intersection(bounds)
            guard !visible.isNull, visible.width > 20, visible.height > 20 else { return nil }
            return CGRect(x: (visible.minX - bounds.minX) * pixels, y: (visible.minY - bounds.minY) * pixels,
                          width: visible.width * pixels, height: visible.height * pixels).integral
        }
        let dot = pointing.flatMap { bounds.contains($0.point) ? CGPoint(x: ($0.point.x - bounds.minX) * pixels, y: ($0.point.y - bounds.minY) * pixels) : nil }
        var images: [ScreenImage] = []
        if let full = Self.jpeg(image, maxWidth: 1400, box: area, dot: dot) {
            let scale = min(1, 1400 / CGFloat(image.width))
            let size = CGSize(width: Int(CGFloat(image.width) * scale), height: Int(CGFloat(image.height) * scale))
            lastShot = (bounds, size)
            let grid = "\(Int(size.width))×\(Int(size.height)) px — click_at uses these pixel coordinates"
            images.append(ScreenImage(label: area == nil ? "The screen (\(grid)):"
                                      : "The screen (\(grid); red box: the area around the user's mouse pointer; red dot: the pointer):", jpeg: full))
        }
        if let area, let crop = image.cropping(to: area), let closeUp = Self.jpeg(crop, maxWidth: 1100, box: nil, dot: nil) {
            images.append(ScreenImage(label: "Close-up of the area the user is pointing at:", jpeg: closeUp))
        }
        return images
    }

    /// Scales to at most `maxWidth` and marks `box`/`dot` (given in the image's top-left pixel space).
    static func jpeg(_ image: CGImage, maxWidth: CGFloat, box: CGRect?, dot: CGPoint?) -> Data? {
        let scale = min(1, maxWidth / CGFloat(image.width))
        let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Core Graphics draws bottom-up.
        ctx.setStrokeColor(red: 1, green: 0.16, blue: 0.22, alpha: 1)
        ctx.setFillColor(red: 1, green: 0.16, blue: 0.22, alpha: 0.9)
        if let box {
            ctx.setLineWidth(3)
            ctx.stroke(CGRect(x: box.minX * scale, y: CGFloat(height) - box.maxY * scale, width: box.width * scale, height: box.height * scale).insetBy(dx: -3, dy: -3))
        }
        if let dot {
            ctx.fillEllipse(in: CGRect(x: dot.x * scale - 6, y: CGFloat(height) - dot.y * scale - 6, width: 12, height: 12))
        }
        guard let marked = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: marked).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    private var askedForScreen = false

    /// What's on screen right now, compactly: focused field, selection, visible buttons/fields/links.
    func screenSummary() async -> String {
        await AX.snapshot(browser: browser).describe(maxElements: 45)
    }

    // MARK: Agent tools

    private func runTool(_ call: ToolCall) async -> String {
        let label = toolLabel(call)
        addStep(label, status: .running)
        defer { finishStep(label) }
        let result = await performTool(call, label: label)
        Log.info("  ↳ \(label) → \(result.replacingOccurrences(of: "\n", with: " ").prefix(220))")
        return result
    }

    private func performTool(_ call: ToolCall, label: String) async -> String {
        do {
            switch call.name {
            case "open_app": return try await execute(.openApp(call.string("name"))) ?? "Opened."
            case "quit_app": return try await execute(.quitApp(call.string("name"))) ?? "Quit."
            case "open_url":
                var raw = call.string("url").trimmingCharacters(in: .whitespaces)
                if raw.hasPrefix("~") || raw.hasPrefix("/") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
                    return "Opened \(raw)."
                }
                if !raw.contains("://") { raw = "https://" + raw }
                guard let url = URL(string: raw) else { return "Invalid URL." }
                try await browser.open(url, forceNewTab: call.bool("new_tab"))
                return "Opened \(url.absoluteString)."
            case "web_search":
                let site = SearchSite(rawValue: call.string("site").lowercased()) ?? .google
                try await browser.open(site.url(for: call.string("query")))
                return "Showing \(site.displayName) results for \(call.string("query"))."
            case "browser":
                guard let action = BrowserAction(rawValue: call.string("action")) else { return "Unknown browser action." }
                try await browser.perform(action)
                return "Done: \(action.rawValue)."
            case "read_screen":
                return await readScreen()
            case "read_page":
                if let text = await browser.pageText(), !text.isEmpty { return text }
                let text = AX.readableText()
                if text.count > 200 { return text }
                return await readScreen()
            case "click":
                return try await click(call.string("target"))
            case "click_at":
                return try await clickAt(call)
            case "menu":
                let path = call.string("path").components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard let chosen = AX.pressMenu(path) else {
                    return "Error: no menu item “\(path.joined(separator: " > "))” in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "the front app")."
                }
                return "Chose \(chosen)."
            case "open_search_result":
                _ = try await execute(.openResult(call.int("number") ?? 1))
                if let tab = try? await browser.currentTab() { return "Opened \(tab.title) — \(tab.url)" }
                return "Opened result."
            case "type_text":
                _ = try await execute(.typeText(call.string("text")))
                return "Typed."
            case "press_keys":
                guard let combo = KeyCombo(spoken: call.string("keys")) else { return "I don't know the keys \(call.string("keys"))." }
                _ = try await execute(.pressKeys(combo))
                return "Pressed \(combo)."
            case "scroll":
                let direction = ScrollDirection(rawValue: call.string("direction")) ?? .down
                let target = call.string("target")
                guard !target.isEmpty else {
                    _ = try await execute(.scroll(direction, .medium))
                    return "Scrolled."
                }
                // Scroll wheel events go to whatever is under the pointer, so put it over that area first.
                guard let hit = AX.find(label: target) else { return "I couldn't find “\(target)” to scroll." }
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: hit.frame.midX, y: hit.frame.midY),
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                try await Task.sleep(nanoseconds: 60_000_000)
                Keyboard.scroll(direction, .medium)
                return "Scrolled \(direction.rawValue) at “\(target)”."
            case "system":
                guard let action = SystemAction(rawValue: call.string("action")) else { return "Unknown action." }
                return try await SystemControl.perform(action, value: call.int("value")) { await self.waitForKeysReleased() }
            case "run_shell":
                let command = call.string("command")
                if Shell.needsConfirmation(command) {
                    guard await confirm("Run this command? \(command)") else { return "The user declined." }
                }
                return try await Shell.run(command, timeout: 120)
            case "download":
                guard let url = URL(string: call.string("url")) else { return "Invalid URL." }
                let file = try await Downloader.download(url)
                return "Saved to \(file.path)."
            case "schedule_task":
                guard let trigger = Scheduler.trigger(from: call.string("when")) else { return "I couldn't understand when: \(call.string("when"))." }
                let automation = scheduler.add(Automation(trigger: trigger, task: call.string("instruction"),
                                                          reminder: call.bool("reminder"), createdBy: "Hark"))
                return "Scheduled: \(automation.summary)."
            case "watch_folder":
                let folder = call.string("folder").isEmpty ? "~/Downloads" : call.string("folder")
                let automation = scheduler.add(Automation(trigger: .newFile(folder: folder), task: call.string("instruction"),
                                                          reminder: false, createdBy: "Hark"))
                return "Watching: \(automation.summary)."
            case "watch_screen", "watch_app":
                let place = (call.arguments["where"] ?? call.arguments["app"] ?? "here").trimmingCharacters(in: .whitespaces)
                let text = call.string("text").isEmpty ? nil : call.string("text")
                let scope: WatchSpec.Scope = place.lowercased() == "here" ? .here
                    : (["anywhere", "screen", "any app"].contains(place.lowercased()) ? .anywhere : .app(place))
                // A click is stored as a plain "click X", which fires instantly with no model involved.
                let action = call.string("click").isEmpty ? call.string("instruction") : "click \(call.string("click"))"
                guard !action.isEmpty else { return "Say what to do when it fires: click or instruction." }
                let watch = await makeWatch(WatchSpec(scope: scope, text: text, action: action))
                let automation = scheduler.add(Automation(trigger: .screenWatch(watch), task: action, reminder: false, createdBy: "Hark"))
                if let rect = watch.rect { flash(rect, .confirm) }
                return "Watching: \(automation.summary)."
            case "list_tasks":
                if scheduler.automations.isEmpty { return "No scheduled tasks." }
                return scheduler.automations.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }.joined(separator: "\n")
            case "cancel_task":
                guard let n = call.int("number"), n >= 1, n <= scheduler.automations.count else { return "No such task." }
                let removed = scheduler.automations[n - 1]
                scheduler.remove(removed.id)
                return "Cancelled: \(removed.summary)."
            case "claude_code":
                return try await ClaudeBridge.send(call.string("prompt")) { await self.waitForKeysReleased() }
            case "wait":
                let seconds = Double(call.string("seconds")) ?? 1
                try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 120)) * 1_000_000_000))
                return "Waited."
            default:
                return "Unknown tool \(call.name)."
            }
        } catch {
            markStepFailed(label)
            return "Error: \(error.localizedDescription)"
        }
    }

    private func toolLabel(_ call: ToolCall) -> String {
        switch call.name {
        case "open_app": return "Open \(call.string("name"))"
        case "web_search": return "Search “\(call.string("query"))”"
        case "open_url": return "Open \(URL(string: call.string("url"))?.host ?? call.string("url"))"
        case "read_screen": return "Look at the screen"
        case "read_page": return "Read the page"
        case "click": return "Click “\(call.string("target"))”"
        case "click_at": return "Click at \(call.string("x")), \(call.string("y"))"
        case "menu": return "Menu \(call.string("path"))"
        case "open_search_result": return "Open result \(call.string("number"))"
        case "type_text": return "Type “\(call.string("text").prefix(30))”"
        case "press_keys": return "Press \(call.string("keys"))"
        case "run_shell": return "Run \(call.string("command").prefix(40))"
        case "schedule_task": return "Schedule “\(call.string("instruction").prefix(30))”"
        case "watch_folder": return "Watch \(call.string("folder"))"
        case "watch_screen", "watch_app": return "Watch \(call.arguments["where"] ?? call.string("app"))"
        case "claude_code": return "Ask Claude Code"
        default: return call.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func readScreen() async -> String {
        var snapshot = await AX.snapshot(browser: browser)
        if snapshot.elements.count < 8, ScreenText.hasPermission,
           let lines = try? await ScreenText.recognize(fast: true) {
            snapshot.ocrText = lines.map(\.text).joined(separator: "\n")
        }
        return snapshot.describe()
    }

    private func click(_ target: String) async throws -> String {
        // An empty label matches everything: never click "something".
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty else {
            throw HarkError("click needs the button's label or text; for an unlabeled icon, take a screenshot and use click_at.")
        }
        if target.matches(#"\b(send|delete|remove|buy|purchase|pay|place order|checkout|transfer|unsubscribe|publish|post|submit|confirm|erase)\b"#) {
            guard await confirm("Click “\(target)”?") else { return "Cancelled." }
        }
        // Pressing through Accessibility needs no mouse, so it can happen while ⌥⌘ is still held.
        if AX.click(label: target, allowMouse: false) { return "Clicked \(target)." }
        await waitForKeysReleased()
        // A pane or page that just opened may still be drawing: give it a moment before deciding it isn't there.
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 450_000_000) }
            if AX.click(label: target) { return "Clicked \(target)." }
            if ScreenText.hasPermission, try await ScreenText.click(text: target) { return "Clicked \(target)." }
        }
        // Say what is there, so the next try can aim right (by another label, or click_at on the screenshot).
        let visible = await AX.snapshot(browser: browser).describe(maxElements: 30)
        throw HarkError("I couldn't find “\(target)” on screen. What's clickable now:\n\(visible)\nLook with screenshot and use click_at if it has no label.")
    }

    /// The latest screenshot's geometry, so click_at can turn its pixels back into screen points.
    private var lastShot: (bounds: CGRect, size: CGSize)?

    private func clickAt(_ call: ToolCall) async throws -> String {
        guard let shot = lastShot, let x = Double(call.string("x")), let y = Double(call.string("y")) else {
            return "Call screenshot first, then click_at with its pixel coordinates."
        }
        let point = CGPoint(x: shot.bounds.minX + x * shot.bounds.width / shot.size.width,
                            y: shot.bounds.minY + y * shot.bounds.height / shot.size.height)
        guard shot.bounds.contains(point) else { return "That point is outside the screenshot." }
        await waitForKeysReleased()
        Keyboard.click(at: point, right: call.string("button") == "right", count: call.bool("double") ? 2 : 1)
        return "Clicked at \(Int(x)), \(Int(y))."
    }

    /// True when "search for X" should be a Google search: from a blank/new tab or Google itself, or with no app in front.
    private func searchGoesToGoogle(url: String?) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        let name = front?.localizedName ?? ""
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier || name.isEmpty { return true }
        guard Browser.all.contains(name) else { return false }
        let url = url ?? ""
        return url.isEmpty || url.contains("newtab") || url.hasPrefix("about:") || url.contains("://www.google.") || url.contains("://google.")
    }

    /// Search where the user is: the page's or app's own search box; Google from a new tab or as a last resort.
    private func searchHere(_ query: String) async throws {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let url = Browser.all.contains(name) ? (try? await browser.currentTab())?.url : nil
        if searchGoesToGoogle(url: url) {
            try await browser.open(SearchSite.google.url(for: query))
            return
        }
        // On a website: that site's own results page, in the same tab (YouTube results on YouTube).
        if Browser.all.contains(name), let host = url.flatMap({ URL(string: $0)?.host }),
           let url = await SiteSearch.shared.url(host: host, query: query) {
            try await browser.open(url, replaceCurrent: true)
            Log.info("Searched \(host) for “\(query)”")
            return
        }
        // Otherwise the page's or app's own search box (never the browser's address bar).
        if !AX.focusSearchField() {
            if Browser.all.contains(name) {
                // A site without a search box: search the web instead.
                try await browser.open(SearchSite.google.url(for: query), forceNewTab: true)
                return
            }
            // Most Mac apps open their search with ⌘F.
            await waitForKeysReleased()
            try Keyboard.press(KeyCombo(key: "f", command: true))
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        if !AX.insertText(query) {
            await waitForKeysReleased()
            try await Keyboard.type(query)
        }
        await waitForKeysReleased()
        try Keyboard.press(KeyCombo(key: "return"))
        Log.info("Searched in \(name) for “\(query)”")
    }

    private func selectionText() async -> String? {
        if let text = AX.selectedText() { return text }
        await waitForKeysReleased()
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let saved = Keyboard.clipboardString()
        try? Keyboard.press(KeyCombo(key: "c", command: true))
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        if let saved { pasteboard.clearContents(); pasteboard.setString(saved, forType: .string) }
        return text
    }

    private func pointMouseAtFrontWindow() {
        guard let app = AX.frontmostApp(), let window = AX.focusedWindow(app), let frame = AX.frame(window) else { return }
        let mouse = NSEvent.mouseLocation
        let flipped = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
        if !frame.contains(flipped) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: frame.midX, y: frame.midY), mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    // MARK: Confirmation

    public enum Approval: String, Sendable { case yes, session, no }

    /// Asks before something sensitive. Answer by voice (Hark listens right away, no keys needed)
    /// or with the island's buttons. Auto mode and "don't ask again" skip the question.
    public func confirm(_ question: String) async -> Bool {
        if settings.autoApprove || approveForSession {
            Log.info("Auto-approved: \(question)")
            addStep("Approved: " + question.trimmingCharacters(in: CharacterSet(charactersIn: "?")), status: .done)
            return true
        }
        confirmationPrompt = question
        reply = question
        answerHeard = ""
        Log.info("Asking: \(question)")
        tick()
        if phase != .listening, !dryRun {
            listeningForAnswer = true
            startHandsFree()
        }
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            confirmation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, self.confirmation != nil, self.confirmationPrompt == question else { return }
                self.answerConfirmation(.no, heard: "(no answer)")
            }
        }
        return answer
    }

    /// The island's Yes / Yes, don't ask again / No buttons, and spoken answers.
    public func answerConfirmation(_ approval: Approval, heard: String = "(clicked)") {
        guard let pending = confirmation else { return }
        confirmation = nil
        Log.info("Answer to “\(confirmationPrompt ?? "")”: \(approval.rawValue) — \(heard)")
        confirmationPrompt = nil
        answerHeard = ""
        transcript = ""
        switch approval {
        case .yes: reply = ""
        case .session:
            approveForSession = true
            reply = "Okay — I won't ask again until Hark quits."
        case .no: reply = "Okay, I won't."
        }
        if listeningForAnswer {
            listeningForAnswer = false
            if phase == .listening { endListening() }
        }
        pending.resume(returning: approval != .no)
    }

    /// Reads yes / no / "yes, don't ask again" from what was said; the earliest decisive word wins.
    nonisolated public static func approval(in text: String) -> Approval? {
        let session = #"\b(?:don'?t ask(?: me)? again|stop asking|(?:for|in) (?:this|the) session|always|auto[- ]?approve|approve (?:everything|all))\b"#
        let no = #"\b(?:no|nope|nah|cancel|stop|never|skip|don'?t|do not)\b"#
        let yes = #"\b(?:yes|yeah|yep|yup|ya|sure|ok|okay|do it|go ahead|confirm|approve|allow|proceed|continue|submit|run it|of course|absolutely|correct|haan)\b"#
        // Blank out "don't ask again" etc. (same length, so positions still line up) before looking for yes/no.
        var masked = text.lowercased()
        var sessionOffset: Int?
        while let range = masked.range(of: session, options: .regularExpression) {
            sessionOffset = sessionOffset ?? masked.distance(from: masked.startIndex, to: range.lowerBound)
            masked.replaceSubrange(range, with: String(repeating: " ", count: masked[range].count))
        }
        func first(_ pattern: String) -> Int? {
            masked.range(of: pattern, options: .regularExpression).map { masked.distance(from: masked.startIndex, to: $0.lowerBound) }
        }
        let noOffset = first(no), yesOffset = first(yes)
        if let noOffset, noOffset < min(yesOffset ?? .max, sessionOffset ?? .max) { return .no }
        if sessionOffset != nil { return .session }
        if yesOffset != nil { return .yes }
        return noOffset != nil ? .no : nil
    }

    // MARK: Screen watchers

    private func makeWatch(_ spec: WatchSpec) async -> ScreenWatch {
        var spec = spec
        if spec.text == WatchSpec.currentSite {
            let host = (try? await browser.currentTab()).flatMap { URL(string: $0.url)?.host }?.replacingOccurrences(of: "www.", with: "")
            spec.text = host ?? "http"
        }
        switch spec.scope {
        case .here:
            // Waiting for text, or for a button to click, needs the whole panel, not just the line under the pointer.
            let wide = spec.text != nil || spec.action.lowercased().hasPrefix("click")
            let minimum = wide ? CGSize(width: 420, height: 300) : CGSize(width: 220, height: 90)
            let (app, rect) = RegionPicker.region(at: pointerForHere, atLeast: minimum)
            return ScreenWatch(app: app, region: rect, text: spec.text)
        case .app(let name):
            return ScreenWatch(app: AppCatalog.shared.resolve(name)?.name ?? name, region: nil, text: spec.text)
        case .anywhere:
            return ScreenWatch(app: nil, region: nil, text: spec.text)
        }
    }

    public func flash(_ rect: CGRect, _ style: Highlight.Style) {
        highlight = Highlight(rect: rect, style: style)
    }

    private var lastAnnouncement: [UUID: Date] = [:]

    private func watchFired(_ automation: Automation, _ watch: ScreenWatch, context: String?) {
        if let rect = watch.rect { flash(rect, .fired) }
        let action = automation.task
        // The watcher is the condition, so an action saved as "if X, click Y" means "click Y" now. And a firing
        // never creates or changes automations — that's how one watcher once multiplied into five.
        let commands = parser.plan(action).flatMap { command -> [Command] in
            if case .watch(let spec) = command { return parser.plan(spec.action) }
            return [command]
        }.filter { command in
            switch command {
            case .watch, .stopWatching, .schedule, .recurring: return false
            default: return true
            }
        }
        // Clicks stay inside the watched area and app, and say nothing when there's nothing to click.
        // Guards like "if there's no such prompt, do nothing" are what a silent miss already does.
        if let first = commands.first, case .click(let target) = first {
            let rest = commands.dropFirst().filter { command in
                if case .agent(let text) = command { return !text.lowercased().matches(#"\b(?:do nothing|otherwise|ignore it|skip it)\b"#) }
                return true
            }
            Task { [weak self] in
                guard let self else { return }
                let clicked = await self.clickForWatcher(target, watch)
                Log.info(clicked ? "Watcher clicked “\(target)”" : "Watcher found no “\(target)” to click")
                guard clicked else { return }
                self.log(heard: "👁 \(watch.label)", result: "Clicked \(target)", ok: true)
                if !rest.isEmpty { self.enqueue(Array(rest), heard: action) }
            }
            return
        }
        if action.lowercased().matches(#"^(?:alert|notify|warn|ping|beep|tell|let|remind)\b"#) {
            if let last = lastAnnouncement[automation.id], Date().timeIntervalSince(last) < 15 { return }
            lastAnnouncement[automation.id] = Date()
            // "remind me that this is a sensitive page" → say the message itself.
            let message = action.firstMatch(#"^(?i:remind|tell|warn|alert|notify) me(?i: that| to| about|,)? (.+)$"#)?[1]
            let text = message.map { "Heads up — " + $0.trimmingCharacters(in: .punctuationCharacters) + "." } ?? context ?? "Something changed."
            log(heard: "👁 \(watch.label)", result: text, ok: true)
            guard phase == .idle || phase == .announcing else { return }
            transcript = "👁 " + watch.label.prefix(1).uppercased() + watch.label.dropFirst()
            reply = text
            steps = []
            phase = .announcing
            scheduleHide(sticky: true)
            tick()
            return
        }
        // Keys and typing must reach the watched app, not whatever the user is working in.
        if commands.contains(where: \.needsKeyboard), let name = watch.app,
           let target = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
            Log.info("Brought \(name) forward for watcher action “\(action)”")
        }
        heardThisTurn = "👁 " + action
        turnFromUser = false
        heardBySpeech = false
        if commands.contains(where: \.isAgent), let context {
            enqueue([.agent("\(action)\n\(context)")], heard: action)
        } else {
            enqueue(commands, heard: action)
        }
    }

    /// Inside the watched app and area only. Accessibility first (no mouse); then the label as it appears on screen —
    /// an exact match, and only while that app is in front, so the click can't land somewhere else.
    private func clickForWatcher(_ target: String, _ watch: ScreenWatch) async -> Bool {
        if AX.click(label: target, app: watch.app, region: watch.rect) { return true }
        guard ScreenText.hasPermission, let area = watch.rect ?? AX.frontWindowFrame(appName: watch.app) else { return false }
        let front = NSWorkspace.shared.frontmostApplication
        if watch.app == nil || watch.app == front?.localizedName {
            return (try? await ScreenText.clickExact(target, in: area)) ?? false
        }
        // The app is behind others (you're working elsewhere). Only if its window really shows the button: wait
        // until you pause typing, bring it forward just for the click, then put your app back.
        guard let app = AX.runningApp(named: watch.app),
              let lines = try? await ScreenText.recognize(app: app.processIdentifier, area: area),
              lines.contains(where: { ScreenText.normalizedLabel($0.text) == ScreenText.normalizedLabel(target) }) else { return false }
        for _ in 0..<40 where CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1.5 {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        app.activate()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let clicked = (try? await ScreenText.clickExact(target, in: area)) ?? false
        try? await Task.sleep(nanoseconds: 150_000_000)
        front?.activate()
        Log.info("Watcher brought \(watch.app ?? "the app") forward to click “\(target)”, then returned to \(front?.localizedName ?? "your app")")
        return clicked
    }

    // MARK: Events

    private func automationFired(_ automation: Automation, context: String?) {
        if case .screenWatch(let watch) = automation.trigger {
            watchFired(automation, watch, context: context)
            return
        }
        if automation.reminder {
            transcript = phase == .listening ? transcript : "Reminder"
            reply = (phase == .listening ? "Reminder: " : "") + automation.task
            if phase != .listening { steps = []; phase = .announcing }
            log(heard: "⏰ \(automation.summary)", result: automation.task, ok: true)
            scheduleHide(sticky: true)
            tick()
            return
        }
        heardThisTurn = "⏰ " + automation.task
        turnFromUser = false
        heardBySpeech = false
        transcript = automation.task
        steps = []
        if let context {
            enqueue([.agent("\(automation.task)\n\(context)")], heard: automation.task)
        } else {
            enqueue(parser.plan(automation.task), heard: automation.task)
        }
    }

    // MARK: Helpers

    public func waitForKeysReleased() async {
        while isHoldingHotkey { try? await Task.sleep(nanoseconds: 30_000_000) }
    }

    private func addStep(_ title: String, status: Step.Status) {
        nowDoing = title
        steps.append(Step(title: title, status: status))
        if steps.count > 8 { steps.removeFirst(steps.count - 8) }
    }

    private func finishStep(_ title: String) {
        if let i = steps.lastIndex(where: { $0.title == title && $0.status == .running }) { steps[i].status = .done }
    }

    private func markStepFailed(_ title: String) {
        if let i = steps.lastIndex(where: { $0.title == title }) { steps[i].status = .failed }
    }

    private func fail(_ message: String) {
        reply = message
        turnOK = false
        tick()
        guard phase != .listening else { return }
        phase = .idle
        scheduleHide()
    }

    private func tidyMemory() async {
        await Transcriber.shared.unloadIfIdle(after: TimeInterval(settings.speechIdleUnload))
        speechModel = await Transcriber.shared.isLoaded ? .ready : .asleep
        brainModel = brainAvailable ? .ready : .unavailable("Claude Code not installed")
    }

    public func refreshModelStatus() async { await tidyMemory() }

    public func unloadEverything() async {
        await Transcriber.shared.unload()
        await tidyMemory()
    }

    private func settingsChanged(_ old: HarkSettings) {
        settings.save()
        let english = settings.englishSpeechModel
        Task { await Transcriber.shared.setVersion(english ? .v2 : .v3) }
        capture.voiceProcessing = settings.noiseSuppression
        if settings.voiceMatch, !old.voiceMatch { Task { await prepareVoiceMatch() } }
        if settings.writerModel != old.writerModel { let model = settings.writerModel; Task { await EditorBrain.shared.setModel(model) } }
    }

    // MARK: Attention

    /// One soft tick-tick when something's done, Hark asks you something, or a reminder or alert arrives.
    /// The island bounces with it, so you know the sound was Hark.
    private func tick() {
        guard !dryRun else { return }
        tickTick()
    }

    private func tickTick() {
        ticks += 1
        for delay in [0.0, 0.14] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let sound = NSSound(named: "Tink")?.copy() as? NSSound else { return }
                sound.volume = 0.55
                sound.play()
            }
        }
    }

    private func log(heard: String, result: String, ok: Bool) {
        let entry = ActivityEntry(heard: heard, result: result, ok: ok)
        activity.insert(entry, at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
        if let data = try? JSONEncoder().encode(Array(activity.prefix(200))) {
            try? data.write(to: Paths.activityFile, options: .atomic)
        }
    }

    private func loadActivity() {
        if !FileManager.default.fileExists(atPath: Paths.activityFile.path) {
            try? FileManager.default.moveItem(at: Paths.legacyActivityFile, to: Paths.activityFile)
        }
        guard let data = try? Data(contentsOf: Paths.activityFile) else { return }
        activity = (try? JSONDecoder().decode([ActivityEntry].self, from: data)) ?? []
    }

    /// Puts the engine into a display state without doing anything. For UI previews and snapshots.
    public func preview(phase: EnginePhase, mode: ListenMode = .command, transcript: String = "", steps: [Step] = [],
                        reply: String = "", level: Float = 0, confirmation: String? = nil) {
        self.phase = phase
        self.mode = mode
        self.transcript = transcript
        self.steps = steps
        self.reply = reply
        self.meter.value = level
        self.confirmationPrompt = confirmation
    }

    public func clearActivity() {
        activity = []
        try? FileManager.default.removeItem(at: Paths.activityFile)
    }
}

extension Command {
    /// Needs a model (Claude or the writing model) rather than running instantly.
    var isAgent: Bool {
        switch self {
        case .agent, .edit: return true
        default: return false
        }
    }
}
