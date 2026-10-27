import AppKit
import Combine
import HarkCore
import SwiftUI

/// A small badge beside the pointer that says Hark is using what's under it: while you say "here" or
/// "this section", while Claude looks at it, and when a watcher is set there. No outline over your content.
@MainActor
final class HighlightController {
    private let engine: HarkEngine
    private let panel: NSPanel
    private let model = CursorBadgeModel()
    private var bag = Set<AnyCancellable>()
    private var tracker: Timer?
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 150, height: 30)

    init(engine: HarkEngine) {
        self.engine = engine
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CursorBadge().environmentObject(model))

        engine.$highlight.compactMap { $0 }.receive(on: RunLoop.main)
            .sink { [weak self] highlight in self?.flash(highlight) }
            .store(in: &bag)
        engine.$transcript.combineLatest(engine.$phase).receive(on: RunLoop.main)
            .sink { [weak self] transcript, phase in self?.updateTracking(transcript: transcript, phase: phase) }
            .store(in: &bag)
    }

    private func updateTracking(transcript: String, phase: EnginePhase) {
        let pointing = phase == .listening && engine.mode == .command
            && transcript.range(of: RegionPicker.pointingWords, options: [.regularExpression, .caseInsensitive]) != nil
        if pointing, tracker == nil {
            show("Here", symbol: "scope", hideAfter: nil)
            // Follow the pointer smoothly while you talk about what's under it.
            tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        } else if !pointing, let timer = tracker {
            timer.invalidate()
            tracker = nil
            hide(after: 0.3)
        }
    }

    private func flash(_ highlight: Highlight) {
        switch highlight.style {
        case .looking: show("Looking here", symbol: "eye.fill", hideAfter: 1.8)
        case .confirm: show("Watching here", symbol: "eye.fill", hideAfter: 1.8)
        case .fired: break  // the island and its tick-tick already say something happened
        }
    }

    private func show(_ caption: String, symbol: String, hideAfter delay: TimeInterval?) {
        hideWork?.cancel()
        model.caption = caption
        model.symbol = symbol
        place()
        panel.orderFrontRegardless()
        model.visible = true
        if let delay { hide(after: delay) }
    }

    /// Just below-right of the pointer, like a tooltip.
    private func place() {
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x + 14, y: mouse.y - Self.size.height - 10))
    }

    private func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.tracker == nil else { return }
            self.model.visible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !self.model.visible { self.panel.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

@MainActor
final class CursorBadgeModel: ObservableObject {
    @Published var caption = ""
    @Published var symbol = "scope"
    @Published var visible = false
}

struct CursorBadge: View {
    @EnvironmentObject var model: CursorBadgeModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: model.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.gradient)
            Text(model.caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().strokeBorder(AngularGradient(colors: Theme.spectrum + [Theme.spectrum[0]], center: .center), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        .opacity(model.visible ? 1 : 0)
        .scaleEffect(model.visible ? 1 : 0.85, anchor: .topLeading)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: model.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
