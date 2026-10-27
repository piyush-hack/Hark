import AppKit

@MainActor
public enum SystemControl {
    public static func perform(_ action: SystemAction, value: Int?, keyboardGate: () async -> Void) async throws -> String {
        switch action {
        case .volumeUp: Keyboard.mediaKey(Keyboard.soundUp); return "Volume up"
        case .volumeDown: Keyboard.mediaKey(Keyboard.soundDown); return "Volume down"
        case .mute: try AppleScript.run("set volume with output muted"); return "Muted"
        case .unmute: try AppleScript.run("set volume without output muted"); return "Unmuted"
        case .setVolume:
            let level = max(0, min(100, value ?? 50))
            try AppleScript.run("set volume output volume \(level)\nset volume without output muted")
            return "Volume \(level)%"
        case .play, .pause, .playPause:
            return try mediaPlayback(action)
        case .nextTrack:
            if let player = activePlayer() { try AppleScript.run("tell application \"\(player)\" to next track") } else { Keyboard.mediaKey(Keyboard.mediaNext) }
            return "Next track"
        case .previousTrack:
            if let player = activePlayer() { try AppleScript.run("tell application \"\(player)\" to previous track") } else { Keyboard.mediaKey(Keyboard.mediaPrevious) }
            return "Previous track"
        case .lockScreen:
            await keyboardGate()
            try Keyboard.press(KeyCombo(key: "q", command: true, control: true))
            return "Locked"
        case .sleepDisplay:
            try await Shell.run("pmset displaysleepnow", timeout: 5)
            return "Display asleep"
        case .darkModeOn, .darkModeOff, .toggleDarkMode:
            let value = action == .darkModeOn ? "true" : (action == .darkModeOff ? "false" : "not dark mode")
            try AppleScript.run("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
            return action == .darkModeOff ? "Light mode" : "Dark mode"
        case .screenshot:
            await keyboardGate()
            try Keyboard.press(KeyCombo(key: "3", command: true, shift: true))
            return "Screenshot saved"
        case .brightnessUp: Keyboard.mediaKey(Keyboard.brightnessUp); return "Brighter"
        case .brightnessDown: Keyboard.mediaKey(Keyboard.brightnessDown); return "Dimmer"
        case .showDesktop:
            try await Shell.run("open -a 'Mission Control' --args 1", timeout: 5)
            return "Desktop"
        case .missionControl:
            try await Shell.run("open -a 'Mission Control'", timeout: 5)
            return "Mission Control"
        }
    }

    private static func activePlayer() -> String? {
        for name in ["Spotify", "Music"] where NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == name }) {
            if let state = try? AppleScript.run("tell application \"\(name)\" to get player state as string"), state != "stopped" { return name }
        }
        return nil
    }

    private static func mediaPlayback(_ action: SystemAction) throws -> String {
        let player = activePlayer() ?? ["Spotify", "Music"].first { name in
            NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
        }
        if let player {
            let verb = action == .play ? "play" : (action == .pause ? "pause" : "playpause")
            try AppleScript.run("tell application \"\(player)\" to \(verb)")
        } else {
            Keyboard.mediaKey(Keyboard.mediaPlay)
        }
        return action == .pause ? "Paused" : "Playing"
    }
}

public enum Shell {
    @discardableResult
    public static func run(_ command: String, timeout: TimeInterval = 60, cwd: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let output = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let text = output.string
                if proc.terminationStatus == 0 || !text.isEmpty {
                    continuation.resume(returning: proc.terminationStatus == 0 ? text : "exit \(proc.terminationStatus)\n\(text)")
                } else {
                    continuation.resume(throwing: HarkError("Command failed with exit code \(proc.terminationStatus)."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var string: String {
            lock.lock(); defer { lock.unlock() }
            let text = String(decoding: data, as: UTF8.self)
            return text.count > 6000 ? String(text.prefix(6000)) + "\n…(truncated)" : text
        }
    }

    /// Commands that change or destroy things need a spoken "yes" first.
    public static func needsConfirmation(_ command: String) -> Bool {
        command.matches(#"(^|[;&|\s])(rm|rmdir|mv|sudo|chmod|chown|kill|killall|pkill|shutdown|reboot|halt|dd|mkfs|diskutil|launchctl|defaults\s+(write|delete)|git\s+(push|reset|clean|checkout\s+--|rebase)|npm\s+publish|curl[^|]*\|\s*(ba|z)?sh|osascript|truncate|>\s*/)\b"#)
    }
}

public enum Downloader {
    public static let fileExtensions: Set<String> = [
        "pdf", "zip", "dmg", "pkg", "png", "jpg", "jpeg", "gif", "webp", "svg", "mp4", "mov", "mp3", "wav", "m4a",
        "csv", "xlsx", "xls", "docx", "doc", "pptx", "txt", "json", "tar", "gz", "7z", "epub", "heic", "apk", "iso",
    ]

    public static func isDirectFile(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    public static func download(_ url: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        var name = response.suggestedFilename ?? url.lastPathComponent
        if name.isEmpty { name = "download" }
        var destination = Paths.downloads.appendingPathComponent(name)
        var counter = 1
        let base = destination.deletingPathExtension().lastPathComponent, ext = destination.pathExtension
        while FileManager.default.fileExists(atPath: destination.path) {
            counter += 1
            destination = Paths.downloads.appendingPathComponent("\(base) \(counter)" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }
}
