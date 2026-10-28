import AppKit
import Combine
import HarkCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = HarkEngine()
    let permissions = Permissions()
    private let hotkey = HotkeyMonitor()
    private var hud: HUDController!
    private var highlighter: HighlightController!
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var pressStarted = Date()
    private var lastExternalApp: NSRunningApplication?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            permissions.refresh()
            Snapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[index + 1]), engine: engine, permissions: permissions)
            NSApp.terminate(nil)
            return
        }
        engine.start()
        hud = HUDController(engine: engine)
        highlighter = HighlightController(engine: engine)
        setUpStatusItem()

        hotkey.dictationEnabled = engine.settings.dictationEnabled
        hotkey.onPress = { [weak self] mode in
            guard let self else { return }
            self.pressStarted = Date()
            // While hands-free is on, a press only matters when it's released (a tap ends it).
            if self.engine.handsFree { return }
            self.engine.beginListening(mode: mode)
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            let tap = Date().timeIntervalSince(self.pressStarted) < 0.35
            if self.engine.handsFree {
                if tap { self.engine.endListening() }
                return
            }
            // Tap ⌥⌘ = hands-free (listens and acts until you tap ⌥⌘ again). Hold = push-to-talk.
            if tap, self.engine.mode == .command { self.engine.startHandsFree() } else if tap { self.engine.cancelListening() } else { self.engine.endListening() }
        }
        hotkey.onCancel = { [weak self] in self?.engine.cancelListening() }
        hotkey.start()

        engine.$phase.receive(on: RunLoop.main).sink { [weak self] phase in self?.updateStatusIcon(phase) }.store(in: &bag)
        engine.$settings.map(\.dictationEnabled).removeDuplicates().sink { [weak self] on in self?.hotkey.dictationEnabled = on }.store(in: &bag)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
        lastExternalApp = NSWorkspace.shared.frontmostApplication

        // Keep the ears ready so even the first ⌥⌘ press acts as you speak (≈600 MB; can sleep in Intelligence settings).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task.detached(priority: .utility) { try? await Transcriber.shared.prepare() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in Task { await self?.engine.prepareVoiceMatch() } }

        permissions.refresh()
        if !engine.settings.onboardingDone || !permissions.essentialsGranted {
            showMainWindow(page: .welcome)
        }
    }

    /// hark://run?key=…&text=open%20chrome — run a command (Shortcuts, Raycast, scripts). The key (About page)
    /// stops web pages from driving your Mac. hark://open — show the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "hark" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let text = items.first { $0.name == "text" }?.value
            let key = items.first { $0.name == "key" }?.value
            switch url.host {
            case "run":
                guard let text, !text.isEmpty else { continue }
                guard key == engine.settings.urlKey else {
                    Log.error("Ignored hark://run without a valid key")
                    continue
                }
                // Opening a URL brings Hark forward; hand focus back so keystrokes land where the user was.
                lastExternalApp?.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.engine.handle(text: text) }
            case "bench":
                guard key == engine.settings.urlKey, let dir = items.first(where: { $0.name == "dir" })?.value else { continue }
                Task { await engine.benchmark(folder: URL(fileURLWithPath: dir)) }
            default: showMainWindow(page: .home)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(page: .home)
        return true
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(.idle)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusIcon(_ phase: EnginePhase) {
        let name: String
        switch phase {
        case .listening: name = "waveform.circle.fill"
        case .thinking, .transcribing: name = "ellipsis.circle.fill"
        case .working: name = "bolt.circle.fill"
        default: name = "waveform"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Hark")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Hold ⌥⌘ and speak", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if engine.settings.dictationEnabled {
            let dictation = NSMenuItem(title: "Hold ⌃⌥ to dictate", action: nil, keyEquivalent: "")
            dictation.isEnabled = false
            menu.addItem(dictation)
        }
        menu.addItem(.separator())
        if engine.isBusy || engine.phase != .idle {
            menu.addItem(item("Stop", #selector(stopHark), key: "."))
            menu.addItem(.separator())
        }
        menu.addItem(item("Open Hark…", #selector(openHome), key: ","))
        menu.addItem(item("Automations", #selector(openAutomations)))
        menu.addItem(.separator())
        let auto = item("Auto-Approve Sensitive Actions", #selector(toggleAutoApprove))
        auto.state = engine.settings.autoApprove ? .on : .off
        menu.addItem(auto)
        menu.addItem(item("Reset Island Position", #selector(resetIsland)))
        menu.addItem(item("Free Memory Now", #selector(freeMemory)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Hark", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openHome() { showMainWindow(page: .home) }
    @objc private func stopHark() { engine.stopEverything() }
    @objc private func openAutomations() { showMainWindow(page: .automations) }
    @objc private func toggleAutoApprove() { engine.settings.autoApprove.toggle() }
    @objc private func resetIsland() { hud.resetPosition() }
    @objc private func freeMemory() { Task { await engine.unloadEverything() } }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Window

    func showMainWindow(page: Page) {
        NavigationModel.shared.page = page
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 560)
            window.contentView = NSHostingView(rootView: MainView()
                .environmentObject(engine)
                .environmentObject(engine.scheduler)
                .environmentObject(permissions)
                .environmentObject(NavigationModel.shared))
            window.center()
            window.setFrameAutosaveName("HarkMain")
            mainWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = NSApp.setActivationPolicy(.accessory)
                    self?.permissions.stopPolling()
                }
            }
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissions.refresh()
        permissions.startPolling()
    }
}
