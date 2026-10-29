import AppKit
import AVFoundation
import Combine
import HarkCore

@MainActor
final class Permissions: ObservableObject {
    enum State { case granted, denied, unknown }

    @Published var microphone: State = .unknown
    @Published var accessibility: State = .unknown
    @Published var screenRecording: State = .unknown
    @Published var automation: State = .unknown
    @Published var fullDiskAccess: State = .unknown
    private var timer: Timer?
    private var checkingAutomation = false

    /// Polls only while the window is open (so grants show up live), never in the background.
    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    var essentialsGranted: Bool { microphone == .granted && accessibility == .granted }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: set(\.microphone, .granted)
        case .denied, .restricted: set(\.microphone, .denied)
        default: set(\.microphone, .unknown)
        }
        set(\.accessibility, AX.isTrusted() ? .granted : .unknown)
        set(\.screenRecording, CGPreflightScreenCaptureAccess() ? .granted : .unknown)
        refreshAutomation(bundleID: "com.google.Chrome")
        // The system privacy database is readable only with Full Disk Access.
        let tcc = Paths.home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let readable = FileHandle(forReadingAtPath: tcc).map { try? $0.close(); return true } ?? false
        set(\.fullDiskAccess, readable ? .granted : .unknown)
    }

    private func set(_ key: ReferenceWritableKeyPath<Permissions, State>, _ value: State) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// The answer can take minutes while the app is busy or launching, so it's asked off the main thread, one at a time.
    private func refreshAutomation(bundleID: String) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
            set(\.automation, automation == .granted ? .granted : .unknown)
            return
        }
        guard !checkingAutomation else { return }
        checkingAutomation = true
        Task.detached { [weak self] in
            let state = Permissions.automationState(bundleID: bundleID)
            await self?.finishAutomationCheck(state)
        }
    }

    private func finishAutomationCheck(_ state: State) {
        checkingAutomation = false
        if state != automation { Log.info("Automation permission for Google Chrome: \(state)") }
        set(\.automation, state)
    }

    nonisolated private static func automationState(bundleID: String) -> State {
        var address = AEAddressDesc()
        let status: OSStatus = bundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &address)
            defer { AEDisposeDesc(&address) }
            return AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, false)
        }
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }

    func requestMicrophone() {
        if microphone == .denied { open("Privacy_Microphone"); return }
        Task { _ = await AudioCapture.requestPermission(); refresh() }
    }

    func requestAccessibility() {
        _ = AX.isTrusted(prompt: true)
        open("Privacy_Accessibility")
    }

    func requestScreenRecording() {
        ScreenText.requestPermission()
        open("Privacy_ScreenCapture")
    }

    func requestAutomation() {
        Task {
            _ = try? await AppleScript.run("tell application \"System Events\" to get name of first process")
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
                _ = try? await AppleScript.run("tell application \"Google Chrome\" to count windows")
            }
            refresh()
        }
    }

    func requestFullDiskAccess() {
        open("Privacy_AllFiles")
    }

    func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
