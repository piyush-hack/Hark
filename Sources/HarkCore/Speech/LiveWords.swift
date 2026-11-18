import AVFoundation
import Speech

/// The words of the phrase you're saying, while you say it. The main recognizer only hears a phrase once it ends (and
/// takes ~0.8 s), so the island was blank or a sentence behind. Apple's on-device recognizer streams partial words
/// instead. They're only shown, never acted on: the phrase's real text still comes from the main recognizer. It runs only
/// while a phrase is being spoken and is cancelled the moment the phrase ends, so it never runs alongside that.
public final class LiveWords: @unchecked Sendable {
    /// The words so far, on the main actor; "" when the phrase ended.
    public var onWords: @MainActor (String) -> Void = { _ in }
    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var locale = ""
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var phrase = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init() {}

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return request != nil
    }

    /// A phrase started. `lead` is everything heard of it so far, including the moment before, so first syllables count.
    public func begin(with lead: [Float], locale: String, hints: [String]) {
        guard AppleTranscriber.authorized else { return }
        lock.lock(); defer { lock.unlock() }
        guard request == nil else { return }
        if recognizer == nil || self.locale != locale {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            self.locale = locale
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = Array(hints.prefix(100))
        phrase += 1
        let current = phrase
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let words = result?.bestTranscription.formattedString, !words.isEmpty else { return }
            self.show(words, for: current)
        }
        self.request = request
        if let buffer = buffer(lead) { request.append(buffer) }
    }

    public func append(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard let request, let buffer = buffer(samples) else { return }
        request.append(buffer)
    }

    /// The phrase ended (its real text is on the way) or listening stopped. Late words from it are dropped.
    public func end() {
        lock.lock(); defer { lock.unlock() }
        guard request != nil else { return }
        task?.cancel()
        task = nil
        request = nil
        phrase += 1
    }

    private func show(_ words: String, for current: Int) {
        guard isCurrent(current) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(current) else { return }
            self.onWords(words)
        }
    }

    private func isCurrent(_ current: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == phrase
    }

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, samples.count * MemoryLayout<Float>.size) }
        return buffer
    }
}
