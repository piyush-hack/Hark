import AppKit
import HarkCore

/// Hold ⌥⌘ to command, ⌃⌥ to dictate. Any other key while held means it was a shortcut, so we back off.
@MainActor
final class HotkeyMonitor {
    var onPress: (ListenMode) -> Void = { _ in }
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}
    var dictationEnabled = true

    private var monitors: [Any] = []
    private var active: ListenMode?
    private var retryTimer: Timer?

    func start() {
        install()
        // Global key monitors only work once Accessibility is granted; re-arm when it is.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AX.isTrusted() && !self.armedWithTrust { self.install() }
            }
        }
    }

    private var armedWithTrust = false

    private func install() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        armedWithTrust = AX.isTrusted()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if active != nil {
                active = nil
                onCancel()
            }
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let command = flags == [.option, .command]
        let dictation = dictationEnabled && flags == [.control, .option]

        guard let current = active else {
            if command { active = .command; onPress(.command) } else if dictation { active = .dictation; onPress(.dictation) }
            return
        }
        let held: NSEvent.ModifierFlags = current == .command ? [.option, .command] : [.control, .option]
        if flags == held { return }
        active = nil
        if flags.isSubset(of: held) { onRelease() } else { onCancel() }
    }
}
