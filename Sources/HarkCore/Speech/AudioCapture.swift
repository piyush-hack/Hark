import AVFoundation
import Combine

/// Live microphone level for the orb, published at most ~15 times a second so it never
/// makes the rest of the UI redraw.
@MainActor
public final class AudioLevel: ObservableObject {
    @Published public var value: Float = 0
    private var last = Date.distantPast

    public init() {}

    func push(_ raw: Float) {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.066 else { return }
        last = now
        value = value * 0.4 + raw * 0.6
    }
}

/// Microphone capture at 16 kHz mono. With voice processing on, macOS applies its own echo
/// cancellation, noise suppression, and gain control before Hark ever sees the audio.
///
/// The engine is configured once and kept (stopped) between uses, and all work happens on a
/// private queue — so pressing the hotkey never blocks the UI, and later starts are near-instant.
public final class AudioCapture: @unchecked Sendable {
    public var onSamples: (([Float]) -> Void)?
    public var onLevel: ((Float) -> Void)?
    public var voiceProcessing = true {
        didSet { if oldValue != voiceProcessing { queue.async { self.teardown() } } }
    }

    private let queue = DispatchQueue(label: "dev.hark.audio", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var running = false
    private var configObserver: NSObjectProtocol?
    private var lastBuffer = Date()
    private var watchdog: DispatchSourceTimer?

    public init() {}

    public static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Starts capturing off the main thread; `completion` reports how long it took or the error.
    public func start(completion: @escaping @Sendable (Result<TimeInterval, Error>) -> Void) {
        queue.async {
            let began = Date()
            do {
                try self.startOnQueue()
                completion(.success(Date().timeIntervalSince(began)))
            } catch {
                self.teardown()
                completion(.failure(error))
            }
        }
    }

    public func stop() {
        queue.async { self.stopOnQueue() }
    }

    /// Sets up the audio graph (and voice processing) ahead of time without opening the mic,
    /// so the first press is as fast as every other one.
    public func prewarm() {
        queue.async {
            let began = Date()
            if (try? self.configure()) != nil {
                Log.info(String(format: "Mic prepared in %.0f ms", Date().timeIntervalSince(began) * 1000))
            }
        }
    }

    private func configure() throws -> AVAudioEngine {
        if let engine { return engine }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                Log.error("Voice processing unavailable: \(error.localizedDescription)")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw HarkError("No microphone input available.") }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        monoFormat = mono
        converter = AVAudioConverter(from: mono, to: target)
        engine.prepare()
        // A new mic or output device invalidates the graph; rebuild it on the next press.
        // A new mic or output device (or a page starting audio) invalidates the graph: rebuild it, and if the
        // mic was live (hands-free), bring it straight back so listening never silently dies.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.rebuild(reason: "audio devices changed") }
        }
        self.engine = engine
        return engine
    }

    private func startOnQueue() throws {
        guard !running else { return }
        let engine = try configure()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let mono = monoFormat else { throw HarkError("Microphone isn't ready.") }
        input.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, _ in
            self?.handle(buffer, mono: mono)
        }
        try engine.start()
        running = true
        lastBuffer = Date()
        startWatchdog()
    }

    private func rebuild(reason: String) {
        let wasRunning = running
        teardown()
        guard wasRunning else { prewarm(); return }
        do {
            try startOnQueue()
            Log.info("Mic restarted (\(reason))")
        } catch {
            Log.error("Mic couldn't restart (\(reason)): \(error.localizedDescription)")
        }
    }

    /// If the mic is supposed to be live but no audio has arrived for 2 s, restart it.
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if Date().timeIntervalSince(self.lastBuffer) > 2 { self.rebuild(reason: "no audio for 2 s") }
        }
        timer.resume()
        watchdog = timer
    }

    private func stopOnQueue() {
        watchdog?.cancel()
        watchdog = nil
        guard running, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private func teardown() {
        stopOnQueue()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if voiceProcessing, let engine { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        engine = nil
        converter = nil
    }

    private func handle(_ buffer: AVAudioPCMBuffer, mono: AVAudioFormat) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        queue.async { self.lastBuffer = Date() }
        // Voice processing on macOS can expose several channels; the first carries the processed voice.
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
        monoBuffer.frameLength = buffer.frameLength
        memcpy(monoBuffer.floatChannelData![0], channels[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / mono.sampleRate) + 64
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return monoBuffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrt(sum / Float(samples.count))
        onLevel?(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 45)))
        onSamples?(samples)
    }
}
