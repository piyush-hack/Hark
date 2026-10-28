import CoreML
import FluidAudio
import Foundation

/// Knows your voice, so hands-free Hark ignores people around you.
///
/// A speaker-recognition model (WeSpeaker, on the Neural Engine, ~25 MB) turns a phrase into a 256-number voiceprint;
/// phrases from the same person point the same way. Hark learns yours from what you say while holding ⌥⌘ (that's
/// always you), keeps adapting (a cold, a different mic), and compares each hands-free phrase against it.
public actor VoiceID {
    public static let shared = VoiceID()

    private var extractor: EmbeddingExtractor?
    private var maskLength = 589
    private var samples: [[Float]] = []
    private var voiceprint: [Float]?
    private var loading: Task<Void, Error>?

    /// Phrases needed before Hark starts filtering, and how many it keeps (newest win, so it adapts).
    public static let samplesNeeded = 6
    static let samplesKept = 40
    /// Below this cosine similarity a phrase is someone else. Same speaker is usually 0.55–0.85, others under 0.35.
    public static let threshold: Float = 0.42
    /// Shorter phrases don't carry enough voice to judge.
    static let minimumSamples = 16_000

    private let file: URL?

    /// `file: nil` keeps everything in memory (for tests and tools).
    public init(file: URL? = Paths.appSupport.appendingPathComponent("voiceprint.json")) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([[Float]].self, from: data) {
            samples = saved
            voiceprint = Self.average(saved)
        }
    }

    /// How many of your phrases it has, and whether it's filtering yet.
    public var progress: (samples: Int, ready: Bool) { (samples.count, samples.count >= Self.samplesNeeded) }

    /// Loads (first time: downloads) the model.
    public func prepare() async throws {
        if extractor != nil { return }
        if let loading { return try await loading.value }
        let task = Task {
            let models = try await DiarizerModels.download()
            if let shape = models.embeddingModel.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape,
               shape.count == 2 {
                self.setMaskLength(shape[1].intValue)
            }
            self.setExtractor(EmbeddingExtractor(embeddingModel: models.embeddingModel))
        }
        loading = task
        defer { loading = nil }
        try await task.value
        Log.info("Voice match ready (\(samples.count) samples of your voice)")
    }

    private func setExtractor(_ value: EmbeddingExtractor) { extractor = value }
    private func setMaskLength(_ value: Int) { maskLength = value }

    /// The voiceprint of a phrase (16 kHz mono), or nil if it's too short to tell.
    public func embedding(of audio: [Float]) async -> [Float]? {
        guard audio.count >= Self.minimumSamples else { return nil }
        // Never make a phrase wait for the model to load: judge nothing until it's ready.
        guard let extractor else {
            Task { try? await self.prepare() }
            return nil
        }
        let clip = Array(audio.suffix(160_000))
        let mask = [Float](repeating: 1, count: maskLength)
        guard let raw = try? extractor.getEmbeddings(audio: clip, masks: [mask], minActivityThreshold: 0).first,
              raw.contains(where: { $0 != 0 }) else { return nil }
        return Self.normalized(raw)
    }

    /// Adds a phrase you said (holding ⌥⌘) to what Hark knows about your voice.
    public func learn(_ audio: [Float]) async {
        guard let vector = await embedding(of: audio) else { return }
        // Something very unlike everything so far (another person near the mic) shouldn't teach it.
        if let voiceprint, samples.count >= Self.samplesNeeded, Self.cosine(vector, voiceprint) < Self.threshold { return }
        samples.append(vector)
        if samples.count > Self.samplesKept { samples.removeFirst(samples.count - Self.samplesKept) }
        voiceprint = Self.average(samples)
        save()
        if samples.count == Self.samplesNeeded { Log.info("Voice match learned your voice; hands-free now ignores other voices") }
    }

    /// How much a phrase sounds like you (cosine, -1…1), or nil when there's nothing to compare yet / it's too short.
    public func match(_ audio: [Float]) async -> Float? {
        guard samples.count >= Self.samplesNeeded, let voiceprint, let vector = await embedding(of: audio) else { return nil }
        return Self.cosine(vector, voiceprint)
    }

    public func forget() {
        samples = []
        voiceprint = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        Log.info("Voice match forgot your voice")
    }

    private func save() {
        if let file, let data = try? JSONEncoder().encode(samples) { try? data.write(to: file, options: .atomic) }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { for i in sum.indices { sum[i] += v[i] } }
        return normalized(sum)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
