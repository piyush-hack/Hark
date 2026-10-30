import Foundation

public struct HarkSettings: Codable, Equatable, Sendable {
    public var claudeModel = "sonnet"
    /// The fast model that turns speech into text edits.
    public var writerModel = "haiku"
    /// Seconds the speech model stays in memory after its last use.
    public var speechIdleUnload: Int = Int.max / 2
    public var noiseSuppression = true
    /// Words the speech model gets wrong: names, brands, sites. Matched by sound.
    public var vocabulary = ["bejoyous.ai", "Joyz", "Piyush", "Claude Code"]
    /// English-only Parakeet v2 (best for English) vs multilingual v3 (25 European languages).
    public var englishSpeechModel = true
    /// "parakeet" (NVIDIA, on the Neural Engine) or "apple" (Apple's on-device recognizer for `speechLocale`).
    public var speechEngine = "parakeet"
    public var speechLocale = "en-IN"
    /// Opt-in troubleshooting: keep the last 20 commands' audio and transcripts on this Mac (nothing is trained on it).
    public var keepRecordings = false
    public var claudeProjectDirectory: String?
    public var preferredBrowser: String?
    public var dictationEnabled = true
    /// Hands-free only obeys your voice (learned from what you say while holding ⌥⌘).
    public var voiceMatch = true
    /// Auto mode: sensitive actions (send, delete, buy, risky shell commands) run without asking.
    public var autoApprove = false
    public var onboardingDone = false
    /// Ask GitHub for a newer Hark at launch and every few hours, and offer it in a window.
    public var checkForUpdates = true
    /// A release the user chose to skip; automatic checks stay quiet about it.
    public var skippedVersion: String?
    /// Secret required by hark://run links, so web pages can't drive your Mac.
    public var urlKey = HarkSettings.newKey()

    public init() {}

    public static func newKey() -> String {
        String((0..<20).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
    }

    public init(from decoder: Decoder) throws {
        let defaults = HarkSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? defaults.claudeModel
        writerModel = try c.decodeIfPresent(String.self, forKey: .writerModel) ?? defaults.writerModel
        speechIdleUnload = try c.decodeIfPresent(Int.self, forKey: .speechIdleUnload) ?? defaults.speechIdleUnload
        noiseSuppression = try c.decodeIfPresent(Bool.self, forKey: .noiseSuppression) ?? defaults.noiseSuppression
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? defaults.vocabulary
        englishSpeechModel = try c.decodeIfPresent(Bool.self, forKey: .englishSpeechModel) ?? defaults.englishSpeechModel
        speechEngine = try c.decodeIfPresent(String.self, forKey: .speechEngine) ?? defaults.speechEngine
        speechLocale = try c.decodeIfPresent(String.self, forKey: .speechLocale) ?? defaults.speechLocale
        keepRecordings = try c.decodeIfPresent(Bool.self, forKey: .keepRecordings) ?? defaults.keepRecordings
        claudeProjectDirectory = try c.decodeIfPresent(String.self, forKey: .claudeProjectDirectory)
        preferredBrowser = try c.decodeIfPresent(String.self, forKey: .preferredBrowser)
        dictationEnabled = try c.decodeIfPresent(Bool.self, forKey: .dictationEnabled) ?? defaults.dictationEnabled
        autoApprove = try c.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? defaults.autoApprove
        voiceMatch = try c.decodeIfPresent(Bool.self, forKey: .voiceMatch) ?? defaults.voiceMatch
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? defaults.onboardingDone
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? defaults.checkForUpdates
        skippedVersion = try c.decodeIfPresent(String.self, forKey: .skippedVersion)
        urlKey = try c.decodeIfPresent(String.self, forKey: .urlKey) ?? defaults.urlKey
    }

    public static func load() -> HarkSettings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let settings = try? JSONDecoder().decode(HarkSettings.self, from: data) else {
            let fresh = HarkSettings()
            fresh.save()
            return fresh
        }
        if !String(decoding: data, as: UTF8.self).contains("urlKey") { settings.save() }
        return settings
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Paths.settingsFile, options: .atomic)
    }
}
