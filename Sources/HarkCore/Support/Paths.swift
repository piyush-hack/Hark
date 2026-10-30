import Foundation

public enum Paths {
    public static let appName = "Hark"

    /// Your terminal's PATH (from a login shell, read once), so tools Claude Code starts — MCP servers run with npx, uvx,
    /// node, python from nvm or Homebrew — are found. Apps launched from the Dock only get a bare PATH.
    public static let shellPATH: String = {
        let fallback = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '%s' \"$PATH\""]
        let pipe = Pipe()
        // Read as output arrives; never wait for end-of-file. Shell startups that leave a helper running (gitstatusd,
        // agents, `cmd &`) keep the pipe open forever, which used to hang this — and everything waiting on it — for good.
        let output = LockedText()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { output.append(chunk) }
        }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return fallback }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        let settle = Date().addingTimeInterval(0.5)
        while !output.text.contains("/usr/bin"), Date() < settle { usleep(10_000) }
        pipe.fileHandleForReading.readabilityHandler = nil
        let path = output.text.components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard path.contains("/usr/bin") else { return fallback }
        // Keep Homebrew and the system folders even if the shell profile left them out.
        let parts = path.split(separator: ":").map(String.init)
        return (parts + fallback.split(separator: ":").map(String.init).filter { !parts.contains($0) }).joined(separator: ":")
    }()

    public static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent(appName, isDirectory: true))
    }()

    public static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    public static var automationsFile: URL { appSupport.appendingPathComponent("automations.json") }
    public static var activityFile: URL { appSupport.appendingPathComponent("activity.json") }
    static var legacyActivityFile: URL { appSupport.appendingPathComponent("activity.jsonl") }

    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class LockedText: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
