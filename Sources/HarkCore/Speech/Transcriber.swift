import FluidAudio
import Foundation

/// Parakeet TDT v3 on the Neural Engine. Loaded on first use, released after it sits idle.
public actor Transcriber {
    public static let shared = Transcriber()

    private var asr: AsrManager?
    private var loading: Task<AsrManager, Error>?
    /// v2 = English-only (most accurate for English), v3 = 25 European languages.
    public private(set) var version: AsrModelVersion = .v2

    public func setVersion(_ newValue: AsrModelVersion) {
        guard newValue != version else { return }
        version = newValue
        unload()
    }
    private var lastUse = Date()
    public private(set) var isLoaded = false

    public func prepare() async throws {
        _ = try await manager()
    }

    private func manager() async throws -> AsrManager {
        lastUse = Date()
        if let asr { return asr }
        if let loading { return try await loading.value }
        let version = self.version
        let task = Task { () throws -> AsrManager in
            let start = Date()
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            // One silent pass compiles the Neural Engine graph so the first real request is fast.
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), source: .microphone)
            Log.info(String(format: "Speech model ready in %.2fs", Date().timeIntervalSince(start)))
            return manager
        }
        loading = task
        do {
            let manager = try await task.value
            asr = manager
            isLoaded = true
            loading = nil
            return manager
        } catch {
            loading = nil
            throw error
        }
    }

    /// The last result's confidence (mean token probability, 0–1), for the log.
    public private(set) var lastConfidence: Float = 0

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count > 1_600 else { return "" }
        // Silence after the last word lets the model finish it: tested on Indian-English speech, word errors fell from
        // 15% to 12% ("Command Zid" → "Command Z", "Huck is spelled" → "Hark is spelled").
        var audio = samples + [Float](repeating: 0, count: Self.trailingSilence)
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        let manager = try await manager()
        let result = try await manager.transcribe(audio, source: .microphone)
        lastUse = Date()
        lastConfidence = result.confidence
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let trailingSilence = 7_200  // 0.45 s

    public func unloadIfIdle(after seconds: TimeInterval) {
        guard asr != nil, Date().timeIntervalSince(lastUse) > seconds else { return }
        unload()
    }

    public func unload() {
        asr?.cleanup()
        asr = nil
        isLoaded = false
        Log.info("Speech model unloaded")
    }
}

/// Splits live audio at natural pauses so commands run while you're still talking.
/// Works on 20 ms frames against an adaptive noise floor (the mic is already noise-suppressed),
/// so a phrase is handed over ~0.4 s after you stop — no model, no extra memory.
public actor Segmenter {
    private var audio: [Float] = []
    private var frameBuffer: [Float] = []
    private var recentLevels: [Float] = []
    private var speechFrames = 0
    private var silenceFrames = 0
    private var inSpeech = false
    /// Frames of quiet since the last voice, so the engine can tell "finished a thought" from "between words".
    private var quietFrames = 0
    public var quietSeconds: Double { Double(quietFrames * Self.frame) / 16_000 }

    static let frame = 320            // 20 ms at 16 kHz
    static let minSpeechFrames = 10   // 200 ms of voice before a pause counts
    static let endSilenceFrames = 16  // 320 ms of quiet ends a phrase
    static let keepTailFrames = 6     // keep 120 ms of the pause so word endings aren't clipped
    static let preRollFrames = 15     // 300 ms kept before speech starts, so first syllables aren't clipped
    static let maxPhraseSamples = 16_000 * 15  // never hold more than 15 s: steady noise or a long monologue still flows

    public init() {}

    public func prepare() async {}

    public func reset() async {
        audio.removeAll(keepingCapacity: true)
        frameBuffer.removeAll(keepingCapacity: true)
        speechFrames = 0
        silenceFrames = 0
        inSpeech = false
        recentLevels.removeAll(keepingCapacity: true)
        quietFrames = 0
    }

    /// The room's noise: the quiet end (10th percentile) of the last 1.5 s, so steady noise never counts as speech.
    private var noiseFloor: Float {
        guard recentLevels.count >= 10 else { return 0.003 }
        return recentLevels.sorted()[recentLevels.count / 10]
    }

    /// Returns finished phrases.
    public func append(_ samples: [Float]) async -> [[Float]] {
        audio.append(contentsOf: samples)
        frameBuffer.append(contentsOf: samples)
        var segments: [[Float]] = []
        while frameBuffer.count >= Self.frame {
            var sum: Float = 0
            for i in 0..<Self.frame { sum += frameBuffer[i] * frameBuffer[i] }
            frameBuffer.removeFirst(Self.frame)
            let rms = sqrt(sum / Float(Self.frame))
            recentLevels.append(rms)
            if recentLevels.count > 75 { recentLevels.removeFirst() }
            let threshold = max(noiseFloor * 2.5, 0.007)
            quietFrames = rms > threshold ? 0 : quietFrames + 1
            if rms > threshold {
                inSpeech = true
                speechFrames += 1
                silenceFrames = 0
            } else if inSpeech {
                silenceFrames += 1
            }
            // Long phrase (or a noisy room that never goes quiet): hand over what's there so far.
            if inSpeech, audio.count - frameBuffer.count >= Self.maxPhraseSamples {
                let cut = audio.count - frameBuffer.count
                segments.append(Array(audio.prefix(cut)))
                audio.removeFirst(cut)
                speechFrames = 0
                silenceFrames = 0
            }
            if inSpeech, silenceFrames >= Self.endSilenceFrames {
                if speechFrames >= Self.minSpeechFrames {
                    let consumed = audio.count - frameBuffer.count
                    let cut = max(0, consumed - (silenceFrames - Self.keepTailFrames) * Self.frame)
                    if cut > 4_800 {
                        segments.append(Array(audio.prefix(cut)))
                        audio.removeFirst(cut)
                    }
                }
                inSpeech = false
                speechFrames = 0
                silenceFrames = 0
            }
            // Between phrases keep only a short lead-in. Otherwise minutes of silence (hands-free during a
            // long task) would be glued onto the next phrase: slow to transcribe and full of made-up words.
            if !inSpeech {
                let keep = Self.preRollFrames * Self.frame + frameBuffer.count
                if audio.count > keep + 16_000 { audio.removeFirst(audio.count - keep) }
            }
        }
        return segments
    }

    /// Whatever is left when the key is released.
    public func flush() -> [Float] {
        defer { audio.removeAll(); frameBuffer.removeAll() }
        return audio.count > 4_800 ? audio : []
    }
}
