import Foundation

public enum Paths {
    public static let appName = "Hark"

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
