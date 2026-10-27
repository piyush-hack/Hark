import Foundation

public struct ToolCall: Sendable {
    public let name: String
    public let arguments: [String: String]

    public func string(_ key: String) -> String { arguments[key] ?? "" }
    public func int(_ key: String) -> Int? { arguments[key].flatMap { Int($0) ?? Double($0).map(Int.init) } }
    public func bool(_ key: String) -> Bool { ["true", "1", "yes"].contains(arguments[key]?.lowercased() ?? "") }
}

/// Everything the brain can ask Hark to do. Described in JSON-schema style; ClaudeBrain renders it as text.
public enum Tools {
    public static let all: [[String: Any]] = {
        func tool(_ name: String, _ description: String, _ params: [(String, String, String)] = [], required: [String] = [],
                  enums: [String: [String]] = [:]) -> [String: Any] {
            var properties: [String: Any] = [:]
            for (key, type, desc) in params {
                var p: [String: Any] = ["type": type, "description": desc]
                if let values = enums[key] { p["enum"] = values }
                properties[key] = p
            }
            return ["type": "function", "function": [
                "name": name, "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required],
            ]]
        }
        return [
            tool("open_app", "Open or switch to an app.", [("name", "string", "App name")], required: ["name"]),
            tool("quit_app", "Quit an app.", [("name", "string", "App name")], required: ["name"]),
            tool("open_url", "Open a web address or file path in the browser.", [("url", "string", "Full URL"), ("new_tab", "boolean", "Force a new tab")], required: ["url"]),
            tool("web_search", "Search the web in the browser.", [("query", "string", "Search words"), ("site", "string", "Where to search")],
                 required: ["query"], enums: ["site": SearchSite.allCases.map(\.rawValue)]),
            tool("browser", "Browser tab action in the current browser.", [("action", "string", "Action")], required: ["action"],
                 enums: ["action": BrowserAction.allCases.map(\.rawValue)]),
            tool("read_screen", "Describe the frontmost app: window, page URL, selected text, clickable items, visible text."),
            tool("read_page", "Get the visible text of the current browser page (for summarizing or answering questions)."),
            tool("click", "Click a button, link, or item by its visible text.", [("target", "string", "Visible label text")], required: ["target"]),
            tool("open_search_result", "Open the Nth result on a search results page (1 = first).", [("number", "integer", "Result number")], required: ["number"]),
            tool("type_text", "Type text into the focused field.", [("text", "string", "Text to type")], required: ["text"]),
            tool("press_keys", "Press a key or shortcut, e.g. 'return', 'cmd+t', 'cmd+shift+4'.", [("keys", "string", "Key combo")], required: ["keys"]),
            tool("scroll", "Scroll the front window, or the part of it that contains `target` (e.g. a dialog's title or any text inside the list/panel to scroll).",
                 [("direction", "string", "Direction"), ("target", "string", "Optional visible text inside the area to scroll")], required: ["direction"],
                 enums: ["direction": ["up", "down", "top", "bottom"]]),
            tool("system", "Mac controls: volume, media, dark mode, lock, screenshot.", [("action", "string", "Action"), ("value", "integer", "Volume 0-100 for set_volume")],
                 required: ["action"], enums: ["action": SystemAction.allCases.map(\.rawValue)]),
            tool("run_shell", "Run a zsh command and return its output (files, git, system info).", [("command", "string", "Shell command")], required: ["command"]),
            tool("download", "Download a URL to ~/Downloads.", [("url", "string", "File URL")], required: ["url"]),
            tool("schedule_task", "Run an instruction or reminder later or repeatedly.",
                 [("when", "string", "e.g. 'in 10 minutes', 'at 6pm', 'tomorrow at 9am', 'every day at 9am', 'every 30 minutes'"),
                  ("instruction", "string", "What to do then, as the user would say it"),
                  ("reminder", "boolean", "true ONLY when the user said 'remind me'; then the instruction is spoken instead of done")], required: ["when", "instruction"]),
            tool("watch_folder", "Run an instruction whenever a new file appears in a folder.",
                 [("folder", "string", "Folder path, e.g. ~/Downloads"), ("instruction", "string", "What to do with the new file")], required: ["folder", "instruction"]),
            tool("watch_screen", "Act whenever part of the screen changes or some text appears. 'here' = the area under the mouse. "
                 + "Text is read from the screen itself, so it works in any app. For 'when X shows up, click Y', set text to words that "
                 + "only appear while X is showing (often the button label itself) and click to Y. One watcher per request.",
                 [("where", "string", "'here', an app name, or 'anywhere'"), ("text", "string", "Text to wait for; omit to fire on any change"),
                  ("click", "string", "Button label to click when it fires (preferred for approvals)"),
                  ("instruction", "string", "Otherwise, a plain command for then, e.g. 'alert me', 'type OK'. No conditions — the watcher is the condition.")],
                 required: ["where"]),
            tool("list_tasks", "List scheduled tasks and watchers."),
            tool("cancel_task", "Cancel a scheduled task by number from list_tasks.", [("number", "integer", "Task number")], required: ["number"]),
            tool("claude_code", "Send a prompt to Claude Code (the coding agent).", [("prompt", "string", "What Claude Code should do")], required: ["prompt"]),
            tool("wait", "Pause before the next step.", [("seconds", "number", "Seconds")], required: ["seconds"]),
        ]
    }()

    /// Tool calls in an assistant message (`{"tool_calls":[{"function":{"name","arguments"}}]}`), arguments flattened to strings.
    static func calls(in message: [String: Any]) -> [ToolCall] {
        guard let calls = message["tool_calls"] as? [[String: Any]] else { return [] }
        return calls.compactMap { call in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            var args: [String: Any] = function["arguments"] as? [String: Any] ?? [:]
            if args.isEmpty, let text = function["arguments"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { args = parsed }
            var strings: [String: String] = [:]
            for (key, value) in args {
                switch value {
                case let s as String: strings[key] = s
                case let n as NSNumber: strings[key] = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
                default:
                    if let data = try? JSONSerialization.data(withJSONObject: value), let s = String(data: data, encoding: .utf8) { strings[key] = s }
                }
            }
            return ToolCall(name: name, arguments: strings)
        }
    }
}
