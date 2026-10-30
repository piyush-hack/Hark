import Foundation
import Security

/// A dotted version like 0.10.2, compared number by number (so 0.10 is newer than 0.9, and 1.2 equals 1.2.0).
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    /// Accepts "1.2.3" and tags like "v1.2.3"; anything after "-" or "+" (pre-release, build) is ignored.
    public init?(_ text: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespaces))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        core = core.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public static var running: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    private func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) where a.part(index) != b.part(index) {
            return a.part(index) < b.part(index)
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A published version of Hark, as GitHub Releases describes it.
public struct Release: Equatable, Sendable {
    public let version: AppVersion
    /// What changed: the release text above its first `---` line (below it are install steps for new users).
    public let notes: String
    public let page: URL
    /// The zipped Hark.app the updater installs.
    public let archive: URL?
    public let archiveSize: Int?

    public init(version: AppVersion, notes: String, page: URL, archive: URL?, archiveSize: Int?) {
        self.version = version
        self.notes = notes
        self.page = page
        self.archive = archive
        self.archiveSize = archiveSize
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let size: Int?
        }
        let tagName: String
        let body: String?
        let htmlUrl: URL
        let assets: [Asset]
    }

    public init(githubJSON data: Data) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard let version = AppVersion(release.tagName) else { throw HarkError("The newest release has no version number (\(release.tagName)).") }
        let lines = (release.body ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let notes = lines.prefix { $0.trimmingCharacters(in: .whitespaces) != "---" }.joined(separator: "\n")
        let zip = release.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        self.init(version: version, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), page: release.htmlUrl,
                  archive: zip?.browserDownloadUrl, archiveSize: zip?.size)
    }
}

public enum UpdateFeed {
    /// The newest published release: Info.plist's HarkUpdateFeed, or HARK_UPDATE_FEED (any URL, file:// too) for testing.
    public static var url: URL? {
        let feed = ProcessInfo.processInfo.environment["HARK_UPDATE_FEED"]
            ?? Bundle.main.object(forInfoDictionaryKey: "HarkUpdateFeed") as? String
        return feed.flatMap(URL.init(string:))
    }

    public static func latest() async throws -> Release {
        guard let url else { throw HarkError("This build has no update feed.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hark/\(AppVersion.running?.description ?? "dev")", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HarkError(http.statusCode == 404 ? "No version of Hark has been published yet." : "GitHub didn't answer (\(http.statusCode)). Try again later.")
        }
        return try Release(githubJSON: data)
    }
}

/// Replaces the running Hark.app with a newer, identically signed one, then reopens it.
public enum UpdateInstaller {
    /// Where this copy can install an update, or why it can't update itself.
    public static func destination(for bundle: Bundle = .main) -> Result<URL, HarkError> {
        let app = bundle.bundleURL.resolvingSymlinksInPath()
        let folder = app.deletingLastPathComponent()
        if app.pathExtension != "app" { return .failure(HarkError("This copy of Hark isn't an app bundle, so it can't update itself.")) }
        if app.path.contains("/AppTranslocation/") {
            return .failure(HarkError("macOS is running Hark from a temporary copy. Move Hark to Applications, open it from there, and update again."))
        }
        if app.path.hasPrefix("/Volumes/"), !FileManager.default.isWritableFile(atPath: folder.path) {
            return .failure(HarkError("Hark is running from the disk image. Drag it to Applications, open it from there, and update again."))
        }
        if !FileManager.default.isWritableFile(atPath: folder.path) || !FileManager.default.isWritableFile(atPath: app.path) {
            return .failure(HarkError("Hark can't replace itself in \(folder.path). Download the new version and drag it to Applications."))
        }
        return .success(app)
    }

    /// Downloads the release archive to a temporary file, reporting 0…1 as it goes.
    public static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Hark-update-\(UUID().uuidString).zip")
        let box = ObservationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        return continuation.resume(throwing: HarkError("The download failed (\(http.statusCode))."))
                    }
                    guard let location else { return continuation.resume(throwing: HarkError("The download failed.")) }
                    // The system deletes `location` when this handler returns.
                    do {
                        try FileManager.default.moveItem(at: location, to: target)
                        continuation.resume(returning: target)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// Unzips the archive next to `destination` (same volume, so the swap is a rename) and returns the Hark.app inside.
    public static func unpack(_ archive: URL, nextTo destination: URL) throws -> URL {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
        let apps = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw HarkError("The download doesn't contain Hark.") }
        // Downloads made here aren't quarantined, but an archive that was could pass it on; Gatekeeper would then block the relaunch.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Accepts the new app only if it is Hark, newer than `current`, intact, and signed by the same identity as `current`
    /// (so a tampered download is refused, and macOS keeps the permissions granted to Hark).
    public static func verify(_ app: URL, replacing current: URL, expecting version: AppVersion) throws {
        guard let new = Bundle(url: app), let old = Bundle(url: current), new.bundleIdentifier == old.bundleIdentifier else {
            throw HarkError("The download isn't Hark.")
        }
        guard let newVersion = (new.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init),
              newVersion == version else {
            throw HarkError("The download isn't Hark \(version).")
        }
        var oldCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &oldCode) == errSecSuccess, let oldCode,
              SecCodeCopyDesignatedRequirement(oldCode, [], &requirement) == errSecSuccess, let requirement else {
            throw HarkError("This copy of Hark isn't signed, so it can't check an update. Download the new version instead.")
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw HarkError("The download isn't a signed app.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard status == errSecSuccess else {
            throw HarkError("The download isn't signed like this copy of Hark (error \(status)), so it wasn't installed. Download the new version instead.")
        }
    }

    /// Swaps the new app into place. The running process keeps working: its code is already loaded.
    public static func replace(_ current: URL, with app: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: app, backupItemName: nil, options: .usingNewMetadataOnly)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            throw HarkError("macOS didn't let Hark replace itself. Allow Hark under System Settings → Privacy & Security → App Management, or download the new version.")
        }
    }

    /// Opens `app` once this process has quit.
    public static func relaunchAfterExit(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                             String(ProcessInfo.processInfo.processIdentifier), app.path]
        try process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw HarkError("\((tool as NSString).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private final class ObservationBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        var task: URLSessionDownloadTask?
    }
}
