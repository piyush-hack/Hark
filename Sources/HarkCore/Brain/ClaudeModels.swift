import Foundation

/// The Claude models your Claude Code sign-in can use. Aliases always mean the newest of each family.
public enum ClaudeModels {
    public struct Option: Identifiable, Hashable, Sendable {
        public let id: String
        public let family: String
        public let detail: String
    }

    public static let all: [Option] = [
        Option(id: "fable", family: "Fable", detail: "most capable · slowest"),
        Option(id: "opus", family: "Opus", detail: "smartest for hard, many-step tasks"),
        Option(id: "sonnet", family: "Sonnet", detail: "smart and quick — recommended"),
        Option(id: "haiku", family: "Haiku", detail: "fastest"),
    ]

    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    public static func displayName(_ model: String) -> String {
        guard let m = model.firstMatch(#"^claude-([a-z]+)-(\d+)-(\d+)"#) else { return model }
        return m[1].prefix(1).uppercased() + m[1].dropFirst() + " \(m[2]).\(m[3])"
    }

    /// The exact model behind each alias on this account (from a one-word test call each), cached for a week.
    public static func resolved() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "ClaudeModelNames") as? [String: String] ?? [:]
    }

    /// Asks Claude Code which model each alias is right now; unavailable ones are left out.
    public static func refresh(force: Bool = false) async -> [String: String] {
        let checked = UserDefaults.standard.object(forKey: "ClaudeModelNamesChecked") as? Date ?? .distantPast
        if !force, Date().timeIntervalSince(checked) < 7 * 86_400, !resolved().isEmpty { return resolved() }
        guard let binary = ClaudeBrain.binary else { return [:] }
        let found = await withTaskGroup(of: (String, String?).self) { group in
            for option in all {
                group.addTask {
                    let args = ["-p", "--model", option.id, "--output-format", "json", "--tools", "", "--strict-mcp-config",
                                "--mcp-config", #"{"mcpServers":{}}"#, "--max-turns", "1"]
                    guard let (out, _) = try? await ClaudeBrain.execute(binary, arguments: args, input: "Reply with exactly: OK"),
                          let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                          (json["is_error"] as? Bool) != true,
                          let usage = json["modelUsage"] as? [String: Any] else { return (option.id, nil) }
                    // The CLI also uses a small model on the side; the alias's own model is the one in its family.
                    return (option.id, usage.keys.first { $0.contains(option.id) } ?? usage.keys.first)
                }
            }
            var names: [String: String] = [:]
            for await (alias, model) in group { if let model { names[alias] = model } }
            return names
        }
        if !found.isEmpty {
            UserDefaults.standard.set(found, forKey: "ClaudeModelNames")
            UserDefaults.standard.set(Date(), forKey: "ClaudeModelNamesChecked")
        }
        return found
    }
}

/// The MCP connectors your Claude account (and Claude Code) has: Gmail, Drive, ClickUp, your own servers…
/// Hark can hand a request to them when you've switched them on.
public enum Connectors {
    public struct Server: Identifiable, Hashable, Codable, Sendable {
        public var id: String { name }
        public let name: String
        /// "connected", "pending" (connects on use), "needs-auth", "failed".
        public let status: String
    }

    public static func cached() -> [Server] {
        guard let data = UserDefaults.standard.data(forKey: "MCPServers"),
              let servers = try? JSONDecoder().decode([Server].self, from: data) else { return [] }
        return servers
    }

    /// The list from a Claude Code session's start-up message (~7 s): every configured server and its status.
    public static func discover() async -> [Server] {
        guard ClaudeBrain.binary != nil else { return cached() }
        // claude.ai connectors arrive over the network a few seconds after start-up, so ask only once they're in.
        let probe = LiveClaude(label: "MCP check", systemPrompt: "Reply with exactly: OK", model: "haiku", timeout: 60,
                               arguments: ["--tools", "", "--disallowedTools", "advisor"])
        let found = ServerBox()
        await probe.setEventHandler { event in
            guard event["subtype"] as? String == "init", let list = event["mcp_servers"] as? [[String: Any]] else { return }
            found.set(list.compactMap { entry in
                (entry["name"] as? String).map { Server(name: $0, status: entry["status"] as? String ?? "pending") }
            })
        }
        await probe.prewarm()
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        _ = try? await probe.ask("OK?")
        await probe.stop()
        let servers = found.get()
        guard !servers.isEmpty else { return cached() }
        let sorted = servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(sorted) { UserDefaults.standard.set(data, forKey: "MCPServers") }
        Log.info("MCP servers for Claude: \(sorted.filter { $0.status == "connected" }.count) connected, \(sorted.filter { $0.status == "needs-auth" }.count) need authorizing in claude.ai, \(sorted.filter { $0.status == "failed" }.count) failed")
        return sorted
    }

    /// Servers Claude may use: everything that connected (or is still connecting); not ones that failed or need sign-in.
    public static func usable() -> [String] {
        cached().filter { $0.status == "connected" || $0.status == "pending" }.map(\.name)
    }

    private final class ServerBox: @unchecked Sendable {
        private var servers: [Server] = []
        private let lock = NSLock()
        func set(_ value: [Server]) { lock.lock(); servers = value; lock.unlock() }
        func get() -> [Server] { lock.lock(); defer { lock.unlock() }; return servers }
    }

    /// Claude Code's tool prefix for a server: "claude.ai Google Drive" → "mcp__claude_ai_Google_Drive".
    public static func toolPrefix(_ server: String) -> String {
        "mcp__" + server.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
    }

    /// Plain name for people and for Claude: "claude.ai Google Drive" → "Google Drive".
    public static func displayName(_ server: String) -> String {
        server.hasPrefix("claude.ai ") ? String(server.dropFirst("claude.ai ".count)) : server
    }

}
