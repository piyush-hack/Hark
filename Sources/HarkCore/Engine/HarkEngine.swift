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
    @Published public private(set) var reply = ""
    @Published public private(set) var confirmationPrompt: String?
    /// "Yes, don't ask again": every confirmation is approved until Hark quits.
    @Published public private(set) var approveForSession = false
    /// Hark opened the mic itself to hear the answer to its question.
    @Published public private(set) var listeningForAnswer = false
    private var answerHeard = ""
    /// Phrases of your voice Hark has learned; it filters other voices once it has `VoiceID.samplesNeeded`.
    @Published public private(set) var voiceSamples = 0
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
        claudeBrain.runTool = { [weak self] call in await self?.runTool(call) ?? "Unavailable." }
        claudeBrain.observe = { [weak self] in
            guard let self else { return ("", []) }
            return (self.screenSummary(), await self.screenImages())
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
    }

    /// Call once at launch from the app (not from the CLI).
    public func start() {
        scheduler.onFire = { [weak self] automation, context in self?.automationFired(automation, context: context) }
        scheduler.start()
        housekeeping = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tidyMemory() }
        }
        Task { await segmenter.prepare() }
        capture.prewarm()
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
        // The writing model starts while you talk, so it's ready by the time you finish the sentence.
        if mode == .command { Task { await EditorBrain.shared.prewarm() } }
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
        if settings.voiceMatch, handsFree || listeningForAnswer, !isHoldingHotkey,
           let score = await VoiceID.shared.match(segment), score < VoiceID.threshold {
            Log.info(String(format: "Ignored a voice that isn't yours (match %.2f)", score))
            return
        }
        // Re-hear short leftovers ("Type in") together with what follows; longer phrases keep their own boundaries.
        let combined = mode == .command && !pendingAudio.isEmpty && pendingText.split(separator: " ").count <= 3
        let audio = combined ? pendingAudio + segment : segment
        guard !audio.isEmpty else { return }
        do {
            let text = try await recognize(audio)
            speechModel = .ready
            guard !text.isEmpty else { return }
            // Holding ⌥⌘ means it's you: every real phrase teaches Hark your voice a little more.
            if settings.voiceMatch, isHoldingHotkey, mode == .command, !CommandParser.isNoise(text) {
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
        let text = Vocabulary.correct(SpokenText.normalize(raw, known: settings.vocabulary), terms: settings.vocabulary)
        if text != raw { Log.info("Heard “\(raw)” → “\(text)”") }
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
        // After "type …", more speech keeps typing — unless it's a command, an instruction ("create a table"),
        // or cut off mid-thought ("create a" … "new paragraph"), which waits for the rest.
        // While you're writing, more speech goes to the writing model, which tells content from instructions — unless
        // any part of it is a command ("okay, open Chrome"), which runs and ends writing mode.
        let hasCommand = parser.parse(text).contains { $0.command != nil }
        if writing, pendingText.isEmpty, !hasCommand, CommandParser.isFiller(text) {
            Log.info("Ignored (not a request): “\(text)”")
            commitHeard()
            return
        }
        if writing, pendingText.isEmpty, !hasCommand, !CommandParser.endsMidThought(text) {
            enqueue([.edit(text)], heard: text)
            commitHeard()
            return
        }
        pendingText = Self.joinPhrases(pendingText, text)
        var (ready, remainder) = parser.streamingPlan(pendingText)
        // An in-app search can't be refined as you keep talking, so it waits until the phrase is finished.
        if remainder.isEmpty, let last = ready.last, case .searchHere = last, !searchGoesToGoogle() {
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
        typingContinues && Date().timeIntervalSince(lastTypedAt) < 12
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

    private func commitHeard() {
        committedHeard = [committedHeard, pendingHeard].filter { !$0.isEmpty }.joined(separator: " ")
        pendingHeard = ""
        pendingAudio = []
    }

    /// Runs everything still waiting as if the key had been released (after a pause).
    private func flushPending() {
        var commands = parser.plan(pendingText)
        if writing, commands.count == 1, case .agent(let rest) = commands[0] { commands = [.edit(rest)] }
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
            let text = CommandParser.dictation(dictation)
            enqueue([.typeText(text)], heard: dictation)
            return
        }
        if confirmation != nil {
            // Nothing clear yet: keep the question up (buttons still work) instead of guessing.
            transcript = ""
            if phase == .transcribing { phase = .working }
            return
        }
        var commands = parser.plan(pendingText)
        if writing, commands.count == 1, case .agent(let rest) = commands[0] { commands = [.edit(rest)] }
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
        let commands = parser.plan(text)
        enqueue(commands, heard: text)
    }

    // MARK: Doing

    private func enqueue(_ planned: [Command], heard: String) {
        // Coughs, "yeah"s, and other people's fragments never reach a model.
        let real = !heardBySpeech ? planned : planned.filter { command in
            switch command {
            case .agent(let text), .edit(let text):
                guard writing ? CommandParser.isFiller(text) : CommandParser.isNoise(text) else { return true }
                Log.info("Ignored (not a request): “\(text)”")
                return false
            default: return true
            }
        }
        // In a text field, whatever isn't an instant command is most likely about the text: the writing model takes
        // it (fast), and hands it on to Claude with the screen when it isn't.
        let mapped = real.map { command -> Command in
            if case .agent(let text) = command, turnFromUser, TextEditor.isEditing() { return .edit(text) }
            return command
        }
        // "select from A to B and make it a heading" is one thought: one request, so the model sees the whole intent.
        var commands: [Command] = []
        for command in mapped {
            if case .edit(let next) = command, case .edit(let previous)? = commands.last {
                commands[commands.count - 1] = .edit(previous + ", " + next)
            } else {
                commands.append(command)
            }
        }
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
            let index = steps.firstIndex { $0.title == command.title && $0.status == .pending }
            if let index { steps[index].status = .running }
            if dryRun {
                dryRunLog.append((Double(consumedSamples) / 16_000, command.title))
                if let index { steps[index].status = .done }
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
                if let index { steps[index].status = .done }
                if let result, !result.isEmpty { turnResults.append(result) }
                if !command.isAgent { claudeBrain.note(heard, did: command.title) }
            } catch is CancellationError {
                break
            } catch {
                if let index { steps[index].status = .failed }
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
            if let tab = try? browser.currentTab(), let url = URL(string: tab.url), Downloader.isDirectFile(url) {
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
            let watch = makeWatch(spec)
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
        let field = TextEditor.capture()
        // "select X" outside any text field means picking it on screen.
        if field == nil, let m = request.firstMatch(#"^(?i:select|highlight)(?i: the)?\s+(.+?)[.!]?$"#) {
            return try await click(m[1])
        }
        // Plain words: straight in, no model, no wait.
        if let words = CommandParser.plainText(request) {
            addStep(try await textEditor.apply(["op": "insert", "text": words], app: "", url: nil), status: .done)
            noteTyped()
            recentEdits.append("“\(request)” → Type “\(TextEditor.short(words))”")
            if recentEdits.count > 8 { recentEdits.removeFirst(recentEdits.count - 8) }
            claudeBrain.note(request, did: "Type “\(words)”")
            Log.info(String(format: "Typed instantly in %.0f ms: “%@”", Date().timeIntervalSince(started) * 1000, words))
            return nil
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let tab = Browser.all.contains(app) ? (try? browser.currentTab()) : nil
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
        recentEdits.append("“\(request)” → \(summary)")
        if recentEdits.count > 8 { recentEdits.removeFirst(recentEdits.count - 8) }
        claudeBrain.note(request, did: summary)
        Log.info(String(format: "Edited in %.2fs: %@", Date().timeIntervalSince(started), summary))
        if !say.isEmpty { reply = say }
        return say.isEmpty ? nil : say
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
        // Keys still held: keep listening; the island shows the steps as they happen.
        if phase != .listening { phase = .thinking }
        brainModel = .loading
        claudeBrain.model = settings.claudeModel
        pointing = nil
        if turnFromUser {
            let point = pointerForHere
            let (app, rect) = RegionPicker.region(at: point)
            pointing = (point, app, rect)
            if text.range(of: RegionPicker.pointingWords, options: [.regularExpression, .caseInsensitive]) != nil { flash(rect, .looking) }
        }
        defer { pointing = nil }
        let answer: String
        do {
            answer = try await claudeBrain.run(text, context: currentContext())
            brainModel = .ready
        } catch {
            brainModel = brainAvailable ? .ready : .unavailable("Claude Code not installed")
            throw error
        }
        reply = answer
        return answer
    }

    private func currentContext() -> String {
        var lines: [String] = []
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        lines.append("Now: \(f.string(from: Date()))")
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName { lines.append("Front app: \(app)") }
        if let tab = try? browser.currentTab(), Browser.all.contains(NSWorkspace.shared.frontmostApplication?.localizedName ?? "") {
            lines.append("Browser page: \(tab.title) — \(tab.url)")
        }
        if !turnResults.isEmpty { lines.append("Already done this turn: " + turnResults.joined(separator: "; ")) }
        if !settings.vocabulary.isEmpty { lines.append("Names/addresses the user uses: " + settings.vocabulary.joined(separator: ", ")) }
        if let pointed = pointingContext() { lines.append(pointed) }
        lines.append("[Screen]\n" + screenSummary())
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
            images.append(ScreenImage(label: area == nil ? "The screen:" : "The screen (red box: the area around the user's mouse pointer; red dot: the pointer):", jpeg: full))
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
    func screenSummary() -> String {
        AX.snapshot(browser: browser).describe(maxElements: 45)
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
                if let text = browser.pageText(), !text.isEmpty { return text }
                let text = AX.readableText()
                if text.count > 200 { return text }
                return await readScreen()
            case "click":
                return try await click(call.string("target"))
            case "open_search_result":
                _ = try await execute(.openResult(call.int("number") ?? 1))
                if let tab = try? browser.currentTab() { return "Opened \(tab.title) — \(tab.url)" }
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
                let watch = makeWatch(WatchSpec(scope: scope, text: text, action: action))
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
        var snapshot = AX.snapshot(browser: browser)
        if snapshot.elements.count < 8, ScreenText.hasPermission,
           let lines = try? await ScreenText.recognize(fast: true) {
            snapshot.ocrText = lines.map(\.text).joined(separator: "\n")
        }
        return snapshot.describe()
    }

    private func click(_ target: String) async throws -> String {
        if target.matches(#"\b(send|delete|remove|buy|purchase|pay|place order|checkout|transfer|unsubscribe|publish|post|submit|confirm|erase)\b"#) {
            guard await confirm("Click “\(target)”?") else { return "Cancelled." }
        }
        // Pressing through Accessibility needs no mouse, so it can happen while ⌥⌘ is still held.
        if AX.click(label: target, allowMouse: false) { return "Clicked \(target)." }
        await waitForKeysReleased()
        if AX.click(label: target) { return "Clicked \(target)." }
        if ScreenText.hasPermission, try await ScreenText.click(text: target) { return "Clicked \(target)." }
        throw HarkError("I couldn't find “\(target)” on screen.")
    }

    /// True when "search for X" should be a Google search: from a blank/new tab or Google itself, or with no app in front.
    private func searchGoesToGoogle() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        let name = front?.localizedName ?? ""
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier || name.isEmpty { return true }
        guard Browser.all.contains(name) else { return false }
        let url = (try? browser.currentTab())?.url ?? ""
        return url.isEmpty || url.contains("newtab") || url.hasPrefix("about:") || url.contains("://www.google.") || url.contains("://google.")
    }

    /// Search where the user is: the page's or app's own search box; Google from a new tab or as a last resort.
    private func searchHere(_ query: String) async throws {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        if searchGoesToGoogle() {
            try await browser.open(SearchSite.google.url(for: query))
            return
        }
        // On a website: that site's own results page, in the same tab (YouTube results on YouTube).
        if Browser.all.contains(name), let host = (try? browser.currentTab()).flatMap({ URL(string: $0.url)?.host }),
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
        let saved = pasteboard.string(forType: .string)
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

    private func makeWatch(_ spec: WatchSpec) -> ScreenWatch {
        var spec = spec
        if spec.text == WatchSpec.currentSite {
            let host = (try? browser.currentTab()).flatMap { URL(string: $0.url)?.host }?.replacingOccurrences(of: "www.", with: "")
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
