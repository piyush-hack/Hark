import AppKit

/// "Tell Claude to …": delivers a prompt to Claude Code.
@MainActor
public enum ClaudeBridge {
    static let terminalHosts = ["Terminal", "iTerm2", "Warp", "Ghostty", "WezTerm", "kitty", "Alacritty"]
    static let editorHosts = ["Visual Studio Code", "Code", "Cursor", "Windsurf", "Zed"]

    /// Types the prompt into the Claude Code session you're looking at, or resumes the latest
    /// session in Terminal when no terminal or editor is in front.
    public static func send(_ prompt: String, keyboardGate: () async -> Void) async throws -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        if terminalHosts.contains(front) || editorHosts.contains(front) {
            if !AX.insertText(prompt) {
                await keyboardGate()
                try await Keyboard.type(prompt)
            }
            await keyboardGate()
            try await Task.sleep(nanoseconds: 120_000_000)
            try Keyboard.press(KeyCombo(key: "return"))
            return "Sent to Claude Code in \(front)"
        }
        let directory = latestProjectDirectory() ?? Paths.home.path
        let claude = ClaudeBrain.binary?.path ?? "claude"
        let command = "cd \(shellQuote(directory)) && \(shellQuote(claude)) --continue \(shellQuote(prompt))"
        try AppleScript.run("""
        tell application "Terminal"
            activate
            do script \(AppleScript.quote(command))
        end tell
        """)
        return "Opened Claude Code in \((directory as NSString).lastPathComponent)"
    }

    /// Working directory of the most recently active Claude Code session (ignoring Hark's own brain sessions).
    public static func latestProjectDirectory() -> String? {
        let root = Paths.home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        var newest: (URL, Date)?
        for project in projects where !project.lastPathComponent.contains("claude-brain") {
            for file in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if date > (newest?.1 ?? .distantPast) { newest = (file, date) }
            }
        }
        guard let file = newest?.0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 200_000), as: UTF8.self)
        for line in head.split(separator: "\n") {
            if let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let cwd = json["cwd"] as? String {
                return cwd
            }
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
