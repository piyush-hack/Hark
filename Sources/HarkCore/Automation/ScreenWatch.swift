import AppKit
import ApplicationServices
import ScreenCaptureKit

/// A spoken watch request before it's tied to a place on screen.
public struct WatchSpec: Equatable, Sendable {
    public enum Scope: Equatable, Sendable { case here, app(String), anywhere }
    public var scope: Scope
    /// nil means "any change"; otherwise fire when this text appears (again).
    public var text: String?
    public var action: String

    public init(scope: Scope, text: String?, action: String) {
        self.scope = scope; self.text = text; self.action = action
    }

    /// Placeholder resolved when the watcher is created: the domain of the front browser tab.
    public static let currentSite = "{current-site}"
}

/// A watcher tied to an app and, optionally, a rectangle of the screen.
public struct ScreenWatch: Codable, Equatable, Sendable {
    public var app: String?
    /// Global screen coordinates, top-left origin (CGEvent space): x, y, width, height.
    public var region: [Double]?
    public var text: String?

    public init(app: String?, region: CGRect?, text: String?) {
        self.app = app
        self.region = region.map { [$0.minX, $0.minY, $0.width, $0.height] }
        self.text = text
    }

    public var rect: CGRect? {
        guard let r = region, r.count == 4 else { return nil }
        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }

    public var label: String {
        let place = region != nil ? "this area\(app.map { " of \($0)" } ?? "")" : (app ?? "any app")
        if let text { return "“\(text)” appears in \(place)" }
        return "\(place) changes"
    }
}

/// Picks the part of the screen the user is pointing at.
public enum RegionPicker {
    /// Words that point at the screen ("what's in this section", "around my cursor"): the island outlines the area under the pointer.
    public static let pointingWords = #"\b(?:here|this|that|there|these|those|cursor|pointer|highlight(?:ed|ing)?|section|around)\b"#

    /// Mouse position in CGEvent coordinates (top-left origin of the main display).
    public static var mouse: CGPoint {
        let p = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: height - p.y)
    }

    /// The meaningful UI container under `point` and the app that owns it.
    @MainActor
    public static func region(at point: CGPoint = mouse, atLeast minimum: CGSize = CGSize(width: 220, height: 90)) -> (app: String?, rect: CGRect) {
        let fallback = CGRect(x: point.x - 260, y: point.y - 140, width: 520, height: 280)
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, var element = hit else {
            return (nil, fallback)
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        if let app, Browser.chromium.contains(app.localizedName ?? "") || app.bundleURL.map(AX.isElectron) == true {
            AX.enableWebAccessibility(app)
            if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let again = hit { element = again }
        }
        // Climb from the leaf until we reach something panel-sized, but never the whole window.
        var best = AX.frame(element) ?? fallback
        var current = element
        for _ in 0..<12 {
            guard let parent = AX.value(current, kAXParentAttribute) else { break }
            let next = parent as! AXUIElement // swiftlint:disable:this force_cast
            let role = AX.string(next, kAXRoleAttribute) ?? ""
            if role == "AXWindow" || role == "AXApplication" { break }
            guard let frame = AX.frame(next) else { break }
            if best.width >= minimum.width && best.height >= minimum.height { break }
            best = frame
            current = next
        }
        if best.width < 120 || best.height < 40 { best = best.insetBy(dx: -120, dy: -60) }
        return (app?.localizedName, best)
    }
}

/// Cheap change detection: a 32×32 grayscale thumbnail of a region.
public enum RegionFingerprint {
    public static func capture(_ rect: CGRect) async -> [UInt8]? {
        guard ScreenText.hasPermission else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).intersects(rect) }) ?? content.displays.first else { return nil }
        let bounds = CGDisplayBounds(display.displayID)
        let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let config = SCStreamConfiguration()
        config.sourceRect = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        config.width = max(32, Int(rect.width / 4))
        config.height = max(32, Int(rect.height / 4))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 32 * 32)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        return drew ? pixels : nil
    }

    /// True when more than ~2% of the thumbnail moved noticeably (ignores caret blinks and anti-aliasing).
    public static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 22 { changed += 1 }
        return Double(changed) / Double(a.count) > 0.02
    }
}
