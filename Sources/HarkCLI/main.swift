import AVFoundation
import Foundation
import HarkCore

// harkctl — test Hark's pieces from the terminal.
//
//   harkctl parse "open chrome, new tab and search for ramen"
//   harkctl transcribe clip.wav [more.wav]
//   harkctl listen clip.wav            # streams a file through pause detection like the live mic
//   harkctl run "open chrome and search for ramen"
//   harkctl agent "what's on my screen" [--dry] [--model=sonnet]
//   harkctl screen                     # what Hark sees in the front window

Log.echoToConsole = true
let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else {
    print("usage: harkctl parse|transcribe|listen|run|agent|screen …")
    exit(1)
}
let rest = Array(args.dropFirst())
let modelOverride = rest.first { $0.hasPrefix("--model=") }.map { String($0.dropFirst(8)) }
let text = rest.filter { !$0.hasPrefix("--") }.joined(separator: " ")

func describe(_ commands: [Command]) -> String {
    commands.map { "  • \($0.title)" + ($0.needsKeyboard ? "  [after key release]" : "") }.joined(separator: "\n")
}

func loadSamples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024)!
    var done = false
    converter.convert(to: output, error: nil) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true
        status.pointee = .haveData
        return input
    }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

switch verb {
case "parse":
    let parser = CommandParser()
    for clause in parser.parse(text) { print("clause: “\(clause.text)” → \(clause.command.map(\.title) ?? "agent")") }
    print("plan:\n" + describe(parser.plan(text)))

case "transcribe":
    if rest.contains("--asr=v3") { await Transcriber.shared.setVersion(.v3) }
    for path in rest where !path.hasPrefix("--") {
        let samples = try loadSamples(path)
        let start = Date()
        let words = try await Transcriber.shared.transcribe(samples)
        print(String(format: "[%.2fs] %@", Date().timeIntervalSince(start), words))
    }

case "listen":
    // Streams a recording through the real engine (dry run): shows when each action would fire.
    let samples = try loadSamples(rest[0])
    let engine = await MainActor.run { HarkEngine() }
    try await Transcriber.shared.prepare()
    let clock = Date()
    let log = await engine.simulate(samples)
    for entry in log { print(String(format: "  %5.2fs  %@", entry.seconds, entry.title)) }
    let heard = await MainActor.run { engine.transcript }
    print("  heard: “\(heard)”")
    print(String(format: "  (%.1fs of audio, processed in %.1fs)", Double(samples.count) / 16_000, Date().timeIntervalSince(clock)))

case "run":
    let engine = await MainActor.run { HarkEngine() }
    await MainActor.run { engine.handle(text: text) }
    try await Task.sleep(nanoseconds: 300_000_000)
    while await MainActor.run(body: { engine.isBusy }) { try await Task.sleep(nanoseconds: 100_000_000) }
    let (steps, reply) = await MainActor.run { (engine.steps, engine.reply) }
    for step in steps { print("  \(step.status == .done ? "✓" : (step.status == .failed ? "✗" : "·")) \(step.title)") }
    if !reply.isEmpty { print("reply: \(reply)") }
    try await Task.sleep(nanoseconds: 2_500_000_000)

case "agent":
    // Runs requests through Claude (your Claude Code sign-in). --dry simulates the tools.
    let dry = rest.contains("--dry")
    let brain = await MainActor.run { ClaudeBrain() }
    if let model = modelOverride { await MainActor.run { brain.model = model } }
    if dry {
        await MainActor.run {
            brain.runTool = { call in
                print("  → \(call.name)(\(call.arguments.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")))")
                switch call.name {
                case "read_screen": return "App: Google Chrome\nPage: Flights to Goa — https://www.google.com/travel/flights\nClickable/visible items:\n- [button] Search\n- [link] Cheapest ₹4,210 IndiGo 6:05 AM"
                case "read_page": return "Cheapest flights to Goa: IndiGo ₹4,210 at 6:05 AM, Air India ₹5,020 at 9:40 AM."
                default: return "OK"
                }
            }
        }
    }
    for request in text.components(separatedBy: "||").map({ $0.trimmingCharacters(in: .whitespaces) }) where !request.isEmpty {
        let start = Date()
        let answer = try await brain.run(request, context: "Now: \(Date())\nFront app: Google Chrome")
        print(String(format: "“%@” → (%.1fs) %@", request, Date().timeIntervalSince(start), answer))
    }

case "text":
    let text = AX.windowText(appName: rest.first ?? "Notes")
    print("trusted: \(AX.isTrusted()) · \(text.count) chars")
    print(text.prefix(1500))

case "screen":
    let snapshot = await MainActor.run { AX.snapshot(browser: Browser()) }
    print("accessibility trusted: \(AX.isTrusted())")
    print(snapshot.describe())

default:
    print("unknown command \(verb)")
    exit(1)
}
