import AppKit
import ScreenCaptureKit
import Vision

public struct OCRLine: Sendable {
    public let text: String
    /// Global screen coordinates, top-left origin (same space as CGEvent).
    public let frame: CGRect
}

/// Screenshot + on-device OCR, for apps whose accessibility tree is empty. Needs Screen Recording.
public enum ScreenText {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    public static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    public static func captureMainDisplay() async throws -> (CGImage, CGRect) {
        try await captureDisplay(containing: nil)
    }

    /// The display under `point` (global, top-left origin), or the main one; Hark's own windows left out.
    public static func captureDisplay(containing point: CGPoint?) async throws -> (CGImage, CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        let under = point.flatMap { point in content.displays.first { CGDisplayBounds($0.displayID).contains(point) } }
        guard let display = under ?? content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw HarkError("No display to capture.")
        }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let config = SCStreamConfiguration()
        let bounds = CGDisplayBounds(display.displayID)
        let scale = CGFloat(CGDisplayPixelsWide(display.displayID)) / max(bounds.width, 1)
        config.width = Int(bounds.width * max(scale, 1))
        config.height = Int(bounds.height * max(scale, 1))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, bounds)
    }

    public static func recognize(fast: Bool = false) async throws -> [OCRLine] {
        let (image, bounds) = try await captureMainDisplay()
        return try await recognize(image, bounds: bounds, fast: fast)
    }

    /// Text inside one area of the screen (global, top-left origin): cheaper than the whole display, and it
    /// reads apps that hide their text from Accessibility, like web views and terminals.
    public static func recognize(in area: CGRect, fast: Bool = false) async throws -> [OCRLine] {
        let (display, displayBounds) = try await captureDisplay(containing: CGPoint(x: area.midX, y: area.midY))
        let visible = area.intersection(displayBounds)
        guard !visible.isNull, visible.width > 8, visible.height > 8 else { return [] }
        let scale = CGFloat(display.width) / max(displayBounds.width, 1)
        let pixels = CGRect(x: (visible.minX - displayBounds.minX) * scale, y: (visible.minY - displayBounds.minY) * scale,
                            width: visible.width * scale, height: visible.height * scale).integral
        guard let crop = display.cropping(to: pixels) else { return [] }
        return try await recognize(crop, bounds: visible, fast: fast)
    }

    private static func recognize(_ image: CGImage, bounds: CGRect, fast: Bool) async throws -> [OCRLine] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { obs -> OCRLine? in
                    guard let text = obs.topCandidates(1).first?.string else { return nil }
                    let box = obs.boundingBox
                    let frame = CGRect(x: bounds.minX + box.minX * bounds.width,
                                       y: bounds.minY + (1 - box.maxY) * bounds.height,
                                       width: box.width * bounds.width, height: box.height * bounds.height)
                    return OCRLine(text: text, frame: frame)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = fast ? .fast : .accurate
            request.usesLanguageCorrection = !fast
            do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { continuation.resume(throwing: error) }
        }
    }

    /// Clicks a button whose on-screen text is exactly `target` inside `area` ("1. Yes" and "❯ Yes" count as "Yes";
    /// "Yes, allow all" or chat text mentioning yes doesn't). For watchers, where a wrong click is worse than none.
    public static func clickExact(_ target: String, in area: CGRect) async throws -> Bool {
        let wanted = normalizedLabel(target)
        guard !wanted.isEmpty else { return false }
        let lines = try await recognize(in: area)
        guard let hit = lines.first(where: { normalizedLabel($0.text) == wanted }) else { return false }
        Keyboard.click(at: CGPoint(x: hit.frame.midX, y: hit.frame.midY))
        return true
    }

    /// "❯ 1. Yes", "1 Yes", "1) Yes" and "Yes" are all the button "yes".
    static func normalizedLabel(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"^[\s❯›>»•*\-–]*(?:\d+\s*[.):]?\s+)?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
    }

    /// Text in one app's window inside `area`, even while the window is behind others: ScreenCaptureKit captures
    /// the window itself, not what's on top of it.
    public static func recognize(app pid: pid_t, area: CGRect) async throws -> [OCRLine] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.frame.intersects(area) && $0.frame.width > 100 }
        guard let window = candidates.max(by: { $0.frame.intersection(area).width * $0.frame.intersection(area).height
                                                < $1.frame.intersection(area).width * $1.frame.intersection(area).height }) else { return [] }
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        let visible = area.intersection(window.frame)
        let sx = CGFloat(image.width) / window.frame.width, sy = CGFloat(image.height) / window.frame.height
        let pixels = CGRect(x: (visible.minX - window.frame.minX) * sx, y: (visible.minY - window.frame.minY) * sy,
                            width: visible.width * sx, height: visible.height * sy).integral
        guard let crop = image.cropping(to: pixels) else { return [] }
        return try await recognize(crop, bounds: visible, fast: false)
    }

    /// Clicks the on-screen text that best matches `target`.
    public static func click(text target: String) async throws -> Bool {
        let wanted = target.lowercased()
        let lines = try await recognize()
        let scored = lines.map { ($0, AX.matchScore($0.text.lowercased(), wanted)) }.filter { $0.1 >= 45 }
        guard let best = scored.max(by: { $0.1 < $1.1 })?.0 else { return false }
        Keyboard.click(at: CGPoint(x: best.frame.midX, y: best.frame.midY))
        return true
    }
}
