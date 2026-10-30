import AppKit
import HarkCore
import SwiftUI

/// Looks for a newer Hark on GitHub at launch and every few hours, and offers it in a small window.
/// Installing downloads the signed app, checks it, swaps it into place, and reopens Hark.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading(Double), installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: Release?
    let current = AppVersion.running ?? AppVersion("0")!

    private let engine: HarkEngine
    private var window: NSWindow?
    private var timer: Timer?
    private var work: Task<Void, Never>?
    private static let interval: TimeInterval = 6 * 3600
    private static let lastCheckKey = "LastUpdateCheck"

    init(engine: HarkEngine) {
        self.engine = engine
    }

    /// Checks shortly after launch (once the speech model has warmed up), then hourly whenever six hours have passed.
    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app", UpdateFeed.url != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkAutomatically(force: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutomatically(force: false) }
        }
        timer?.tolerance = 600
    }

    var canInstall: Bool {
        if case .success = UpdateInstaller.destination() { return release?.archive != nil }
        return false
    }

    var isWorking: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// From the menu, the About page, or hark://update: always shows the result.
    func checkNow() {
        present(activate: true)
        Task { await check(userInitiated: true) }
    }

    func install() {
        guard let release, let archive = release.archive, !isWorking else { return }
        let destination: URL
        switch UpdateInstaller.destination() {
        case .success(let url): destination = url
        case .failure(let error):
            phase = .failed(error.message)
            return
        }
        Log.info("Updating Hark \(current) → \(release.version)")
        phase = .downloading(0)
        work = Task {
            do {
                let zip = try await UpdateInstaller.download(archive) { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                    }
                }
                defer { try? FileManager.default.removeItem(at: zip) }
                try Task.checkCancellation()
                phase = .installing
                let app = try await Task.detached(priority: .userInitiated) {
                    let app = try UpdateInstaller.unpack(zip, nextTo: destination)
                    do {
                        try UpdateInstaller.verify(app, replacing: destination, expecting: release.version)
                    } catch {
                        try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                        throw error
                    }
                    return app
                }.value
                try Task.checkCancellation()
                try UpdateInstaller.replace(destination, with: app)
                try UpdateInstaller.relaunchAfterExit(destination)
                Log.info("Installed Hark \(release.version); reopening")
                NSApp.terminate(nil)
            } catch {
                if Task.isCancelled { return phase = .available }
                Log.error("Update failed: \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Closes the window (stopping a download); the next check offers this version again.
    func later() {
        guard phase != .installing else { return }
        work?.cancel()
        work = nil
        phase = release == nil ? .idle : .available
        window?.orderOut(nil)
    }

    func skip() {
        if let release { engine.settings.skippedVersion = release.version.description }
        later()
    }

    func openReleasePage() {
        let page = release?.page ?? UpdateFeed.url.flatMap(Self.releasesPage) ?? URL(string: "https://github.com")!
        NSWorkspace.shared.open(page)
    }

    /// hark://update?install=1 (with the key): check, and install whatever is newer without asking.
    func checkAndInstall() {
        Task {
            await check(userInitiated: true)
            if phase == .available { install() }
        }
    }

    // MARK: Checking

    private func checkAutomatically(force: Bool) {
        guard engine.settings.checkForUpdates, !isWorking, window?.isVisible != true else { return }
        let last = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.lastCheckKey))
        guard force || Date().timeIntervalSince(last) >= Self.interval else { return }
        Task { await check(userInitiated: false) }
    }

    private func check(userInitiated: Bool) async {
        guard !isWorking else { return }
        phase = .checking
        do {
            let latest = try await UpdateFeed.latest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            guard latest.version > current else {
                release = nil
                phase = userInitiated ? .upToDate : .idle
                return
            }
            release = latest
            phase = .available
            Log.info("Hark \(latest.version) is available (running \(current))")
            if !userInitiated, engine.settings.skippedVersion != latest.version.description { presentWhenIdle() }
        } catch {
            Log.error("Update check failed: \(error.localizedDescription)")
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Waits until Hark isn't listening or acting, so the window never lands mid-command.
    private func presentWhenIdle() {
        guard phase == .available else { return }
        guard engine.phase == .idle, !engine.isBusy else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.presentWhenIdle() }
            return
        }
        present(activate: false)
    }

    // MARK: Window

    /// Automatic checks show the window without taking focus, so typing in another app never lands in it.
    private func present(activate: Bool) {
        if window == nil {
            // Clickable on the first click even when shown without focus; the window follows the view's size.
            let host = ClickableHostingView(rootView: UpdateView().environmentObject(self))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.contentView = host
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.later() }
            }
            self.window = window
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    private static func releasesPage(_ feed: URL) -> URL? {
        // api.github.com/repos/<owner>/<repo>/releases/latest → github.com/<owner>/<repo>/releases
        let parts = feed.pathComponents
        guard feed.host == "api.github.com", parts.count >= 4, parts[1] == "repos" else { return nil }
        return URL(string: "https://github.com/\(parts[2])/\(parts[3])/releases")
    }

    /// Fixed states for `Hark --snapshot`.
    func preview(_ phase: Phase, release: Release?) {
        self.phase = phase
        self.release = release
    }
}
