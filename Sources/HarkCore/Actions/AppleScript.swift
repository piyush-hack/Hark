import Foundation

/// In-process AppleScript, so macOS asks for Automation access on behalf of Hark itself.
@MainActor
public enum AppleScript {
    @discardableResult
    public static func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else { throw HarkError("Invalid AppleScript.") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 {
                throw HarkError("Hark isn't allowed to control that app yet. Allow it in System Settings → Privacy & Security → Automation.")
            }
            throw HarkError(message)
        }
        if result.descriptorType == typeAEList {
            return (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1)?.stringValue }.joined(separator: "\n")
        }
        return result.stringValue ?? ""
    }

    public static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
