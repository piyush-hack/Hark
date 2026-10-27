import AppKit
import Carbon.HIToolbox

/// Synthesized keyboard and mouse input. Needs the Accessibility permission.
public enum Keyboard {
    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "=": kVK_ANSI_Equal, "-": kVK_ANSI_Minus, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete, "escape": kVK_Escape,
        "forwarddelete": kVK_ForwardDelete, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "down": kVK_DownArrow, "up": kVK_UpArrow, "home": kVK_Home, "end": kVK_End,
        "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    public static func press(_ combo: KeyCombo) throws {
        guard let code = keyCodes[combo.key] else { throw HarkError("I don't know the key “\(combo.key)”.") }
        var flags: CGEventFlags = []
        if combo.command { flags.insert(.maskCommand) }
        if combo.option { flags.insert(.maskAlternate) }
        if combo.control { flags.insert(.maskControl) }
        if combo.shift { flags.insert(.maskShift) }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else {
            throw HarkError("Couldn't create a key event.")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(8_000)
        up.post(tap: .cghidEventTap)
        usleep(12_000)
    }

    /// Types text by pasting it, then restores the clipboard. Fast and safe for any Unicode.
    @MainActor
    public static func type(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        try press(KeyCombo(key: "v", command: true))
        try await Task.sleep(nanoseconds: 250_000_000)
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    /// Hardware-style media keys (play, next, volume, brightness) so macOS shows its own overlay.
    public static func mediaKey(_ key: Int32) {
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    public static let mediaPlay: Int32 = 16, mediaNext: Int32 = 17, mediaPrevious: Int32 = 18
    public static let soundUp: Int32 = 0, soundDown: Int32 = 1, mute: Int32 = 7
    public static let brightnessUp: Int32 = 2, brightnessDown: Int32 = 3

    public static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    public static func scroll(_ direction: ScrollDirection, _ amount: ScrollAmount) {
        let lines: Int32 = amount == .small ? 3 : (amount == .medium ? 8 : 20)
        let repeats = (direction == .top || direction == .bottom) ? 12 : 1
        for _ in 0..<repeats {
            let (dy, dx): (Int32, Int32) = {
                switch direction {
                case .up, .top: return (lines * 4, 0)
                case .down, .bottom: return (-lines * 4, 0)
                case .left: return (0, lines * 4)
                case .right: return (0, -lines * 4)
                }
            }()
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy * 10, wheel2: dx * 10, wheel3: 0)?
                .post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }
}
