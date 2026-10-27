import AVFoundation
import Speech

/// Apple's on-device recognizer for a regional English (default en-IN): trained on that accent,
/// biased toward your words through `contextualStrings`, and it costs Hark no memory.
public final class AppleTranscriber: @unchecked Sendable {
    public static let shared = AppleTranscriber()
    public var locale = "en-IN" { didSet { recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) } }
    public var contextualStrings: [String] = []
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN"))
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public var isAvailable: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    public static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let recognizer, isAvailable else { throw HarkError("Apple speech recognition for \(locale) isn't available on this Mac.") }
        guard samples.count > 1_600, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return "" }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, samples.count * MemoryLayout<Float>.size) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = Array(contextualStrings.prefix(100))
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    // "No speech detected" is just silence.
                    let nsError = error as NSError
                    once.run {
                        if nsError.code == 1110 || nsError.localizedDescription.lowercased().contains("no speech") {
                            continuation.resume(returning: "")
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}

/// Loads any audio file as 16 kHz mono floats.
public enum AudioFile {
    public static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw HarkError("Can't read \(url.lastPathComponent).")
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw HarkError("Out of memory.") }
        var done = false
        converter.convert(to: output, error: nil) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
