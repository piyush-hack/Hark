import AppKit
import Combine
import HarkCore
import SwiftUI

/// Floating island at the top of the screen. Click-through, never steals focus.
@MainActor
final class HUDController {
    private let panel: NSPanel
    private let engine: HarkEngine
    private let layout = HUDLayout()
    private var screen: NSScreen?
    private var bag = Set<AnyCancellable>()
    private var showWork: DispatchWorkItem?
    static let size = NSSize(width: 560, height: 420)

    init(engine: HarkEngine) {
        self.engine = engine
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Floating, not status-bar level: macOS permission prompts must stay above the island.
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = ClickableHostingView(rootView: HUDView().environmentObject(engine).environmentObject(layout))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        layout.onResize = { [weak self] size in self?.fit(size) }
        layout.onDrag = { [weak self] ended in self?.drag(ended: ended) }
        layout.onResetPosition = { [weak self] in self?.resetPosition() }
        engine.pointerOverIsland = { [weak self] in self?.pointerOverIsland ?? false }

        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.update() } }
            .store(in: &bag)
    }

    private var shouldShow: Bool {
        engine.phase != .idle || !engine.steps.isEmpty || !engine.reply.isEmpty || engine.confirmationPrompt != nil
    }

    /// The island takes clicks while it has something to act on (Stop, scrolling an answer, ×);
    /// while you're just talking it never gets in the way.
    private var interactive: Bool {
        if engine.confirmationPrompt != nil { return true }
        // Hands-free: clickable only when there's an answer to scroll or work to stop.
        if engine.phase == .listening { return engine.handsFree && (engine.isBusy || !engine.reply.isEmpty) }
        return engine.isBusy || engine.phase != .idle || !engine.reply.isEmpty || engine.confirmationPrompt != nil
    }

    /// Where the island itself is drawn (the panel has a transparent margin around it).
    private var islandRect: NSRect {
        let size = layout.size
        return NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private var pointerOverIsland: Bool {
        panel.isVisible && islandRect.contains(NSEvent.mouseLocation)
    }

    private func update() {
        // Under the pointer the island always takes clicks (to drag, minimize, scroll); elsewhere it stays out of the way.
        panel.ignoresMouseEvents = !(interactive || pointerOverIsland)
        if shouldShow {
            guard !panel.isVisible, showWork == nil else { return }
            // A short delay keeps ⌥⌘ shortcuts (like ⌥⌘I) from flashing the island.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.showWork = nil
                if self.shouldShow { self.present() }
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            showWork?.cancel()
            showWork = nil
            if panel.isVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self, !self.shouldShow else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
    }

    private func present() {
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        fit(layout.size == .zero ? CGSize(width: 440, height: 60) : layout.size)
        panel.orderFrontRegardless()
        // While the island is up: take clicks only under the pointer, and step aside whenever a macOS prompt
        // ("Hark would like to access…") appears.
        promptWatch?.invalidate()
        var ticks = 0
        promptWatch = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.panel.isVisible else { self.promptWatch?.invalidate(); self.promptWatch = nil; return }
                self.panel.ignoresMouseEvents = !(self.interactive || self.pointerOverIsland)
                ticks += 1
                if ticks % 4 == 0, self.dragStart == nil { self.fit(self.layout.size) }
            }
        }
    }

    private var promptWatch: Timer?

    // MARK: Position

    /// Where you dragged the island: the top-center point, kept across launches.
    private var anchor: CGPoint? {
        get {
            guard let parts = UserDefaults.standard.string(forKey: "HUDAnchor")?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        set {
            if let newValue { UserDefaults.standard.set("\(newValue.x),\(newValue.y)", forKey: "HUDAnchor") }
            else { UserDefaults.standard.removeObject(forKey: "HUDAnchor") }
        }
    }

    private var dragStart: (mouse: CGPoint, anchor: CGPoint)?

    private func drag(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, CGPoint(x: panel.frame.midX, y: panel.frame.maxY)) }
        guard let start = dragStart else { return }
        anchor = CGPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
        screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? screen
        fit(layout.size)
        if ended { dragStart = nil }
    }

    func resetPosition() {
        anchor = nil
        fit(layout.size)
    }

    /// Hug the island so the panel never covers anything around it — including system prompts.
    private func fit(_ island: CGSize) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame, island != .zero else { return }
        let width = island.width + 48, height = island.height + 40
        var frame = NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 2, width: width, height: height)
        if let anchor {
            // Where you put it, kept fully on screen.
            frame.origin.x = min(max(anchor.x - width / 2, visible.minX - 24), visible.maxX - width + 24)
            frame.origin.y = min(max(anchor.y - height, visible.minY), visible.maxY - height + 2)
        }
        if dragStart == nil, let prompt = Self.systemPromptFrame(), prompt.intersects(frame) {
            frame.origin.y = max(visible.minY, prompt.minY - height - 6)
        }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// Apps that show macOS's own prompts: privacy access, Accessibility, Gatekeeper, passwords.
    private static let promptOwners: Set<String> = ["UserNotificationCenter", "universalAccessAuthWarn", "CoreServicesUIAgent", "SecurityAgent", "tccd"]

    /// Where a macOS prompt is on screen (AppKit coordinates), if one is up. Window owners need no permission to read.
    private static func systemPromptFrame() -> NSRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let height = NSScreen.screens.first?.frame.height ?? 0
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String, promptOwners.contains(owner),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 40, rect.height > 40 else { continue }
            return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

struct HUDView: View {
    @EnvironmentObject var engine: HarkEngine
    @EnvironmentObject var layout: HUDLayout
    /// Goes up on each "tick" of a tick-tick: the island bounces and glows with the sound.
    @State private var pulse = false

    private var visible: Bool {
        engine.phase != .idle || !engine.steps.isEmpty || !engine.reply.isEmpty || engine.confirmationPrompt != nil
    }

    var body: some View {
        VStack {
            if visible {
                Group {
                    if layout.minimized && engine.confirmationPrompt == nil { pill } else { island }
                }
                    .overlay(glow)
                    .scaleEffect(pulse ? 1.035 : 1, anchor: .top)
                    .background(GeometryReader { proxy in Color.clear.preference(key: IslandSizeKey.self, value: proxy.size) })
                    .transition(.asymmetric(insertion: .scale(scale: 0.86, anchor: .top).combined(with: .opacity),
                                            removal: .scale(scale: 0.94, anchor: .top).combined(with: .opacity)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(IslandSizeKey.self) { size in layout.update(size) }
        .onChange(of: engine.ticks) { bounce() }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: visible)
        .environment(\.colorScheme, .dark)
    }

    private var island: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                LiveOrb(meter: engine.meter, mood: engine.phase.mood, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.5))
                        .textCase(.uppercase)
                    // Everything you said, never cut off: long requests scroll, pinned to the newest words.
                    FittedScroll(maxHeight: 132, pinToBottom: true) {
                        Text(headline)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(engine.transcript.isEmpty && engine.phase == .listening ? 0.55 : 0.96))
                            .contentTransition(.opacity)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                }
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .onTapGesture(count: 2) { layout.onResetPosition() }
                Spacer(minLength: 6)
                trailing
                smallButton("minus", help: "Minimize") { layout.setMinimized(true) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if !engine.steps.isEmpty {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(engine.steps) { step in StepRow(step: step) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }

            if showReply {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 14)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: engine.confirmationPrompt != nil ? "questionmark.circle.fill" : "text.bubble.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.gradient)
                        .padding(.top, 2)
                    // The whole answer: as tall as it needs up to most of the screen, then it scrolls.
                    FittedScroll(maxHeight: maxReplyHeight) {
                        // Claude's light formatting (bold, italics, links) shows as formatting, not asterisks.
                        Text((try? AttributedString(markdown: engine.reply, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                             ?? AttributedString(engine.reply))
                            .font(.system(size: 13.5))
                            .lineSpacing(2)
                            .foregroundStyle(.white.opacity(0.88))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if engine.reply.count > 80 {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(engine.reply, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help("Copy")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }

            if engine.confirmationPrompt != nil {
                HStack(spacing: 8) {
                    answerButton("No", style: .plain) { engine.answerConfirmation(.no) }
                    Spacer(minLength: 0)
                    answerButton("Yes, don't ask again", style: .plain) { engine.answerConfirmation(.session) }
                    answerButton("Yes", style: .prominent) { engine.answerConfirmation(.yes) }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .padding(.top, 2)
            }
        }
        .frame(width: 480, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.55)))
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .padding(.top, 4)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: engine.steps)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: engine.reply)
        .animation(.easeOut(duration: 0.15), value: engine.transcript)
    }

    private var showReply: Bool {
        !engine.reply.isEmpty && engine.reply != headline
    }

    private var maxReplyHeight: CGFloat {
        max(160, (NSScreen.main?.visibleFrame.height ?? 800) * 0.6 - 120)
    }

    private var statusLabel: String {
        if engine.confirmationPrompt != nil { return engine.phase == .listening ? "Say yes or no — or click" : "Hold ⌥⌘ and say yes or no — or click" }
        switch engine.phase {
        case .listening: return engine.mode == .dictation ? "Dictating" : (engine.handsFree ? "Hands-free · tap ⌥⌘ to finish" : "Listening")
        case .transcribing: return "Understanding"
        case .thinking: return engine.brainModel == .ready ? "Thinking" : "Waking the brain"
        case .working: return "Working"
        case .announcing: return "Heads up"
        case .idle: return engine.steps.contains { $0.status == .failed } ? "Couldn't finish" : "Done"
        }
    }

    private var headline: String {
        if let prompt = engine.confirmationPrompt { return prompt }
        if !engine.transcript.isEmpty { return engine.transcript }
        if engine.phase == .listening {
            if engine.mode == .dictation { return "Speak — I'll type it" }
            // Hands-free between requests: what was just done, not a standing "I'm listening".
            if engine.handsFree, !engine.nowDoing.isEmpty { return engine.nowDoing }
            return engine.handsFree ? "I'm listening — just talk, I'll act as you go." : "Go ahead, I'm listening…"
        }
        return engine.reply
    }

    @ViewBuilder private var trailing: some View {
        switch engine.phase {
        case .listening where engine.handsFree && engine.isBusy:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                stopButton
            }
        case .listening:
            HStack(spacing: 4) {
                Keycap(symbol: engine.mode == .dictation ? "⌃" : "⌥", dark: true)
                Keycap(symbol: engine.mode == .dictation ? "⌥" : "⌘", dark: true)
            }
            .opacity(0.8)
        case .transcribing, .thinking, .working:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                stopButton
            }
        case .announcing, .idle:
            if !engine.reply.isEmpty || !engine.steps.isEmpty, engine.confirmationPrompt == nil { closeButton }
        }
    }

    private enum AnswerStyle { case plain, prominent }

    private func answerButton(_ title: String, style: AnswerStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(style == .prominent ? 1 : 0.85))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(style == .prominent ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.12))))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Two quick bounces with a spectrum glow, timed to the two ticks.
    private func bounce() {
        for start in [0.0, 0.14] {
            DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                withAnimation(.easeOut(duration: 0.07)) { pulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { pulse = false }
                }
            }
        }
    }

    private var glow: some View {
        RoundedRectangle(cornerRadius: layout.minimized && engine.confirmationPrompt == nil ? 19 : 22, style: .continuous)
            .strokeBorder(AngularGradient(colors: Theme.spectrum + [Theme.spectrum[0]], center: .center), lineWidth: 2)
            .shadow(color: Theme.accent.opacity(0.8), radius: 12)
            .padding(.top, 4)
            .opacity(pulse ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// Drag the island (or the pill) anywhere; double-click its header to put it back on top.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in layout.onDrag(false) }
            .onEnded { _ in layout.onDrag(true) }
    }

    /// What the pill says: the step Hark is on, what it's hearing, or else what it last did — never how to use it.
    /// One line: line breaks become spaces.
    private var pillText: String {
        pillSource.replacingOccurrences(of: "\n", with: " ")
    }

    private var pillSource: String {
        if let prompt = engine.confirmationPrompt { return prompt }
        if engine.isBusy || [.thinking, .working].contains(engine.phase),
           let now = engine.steps.last?.title ?? (engine.transcript.isEmpty ? nil : engine.transcript) { return now }
        if !engine.transcript.isEmpty { return engine.transcript }
        if !engine.nowDoing.isEmpty { return engine.nowDoing }
        return engine.phase == .listening ? "Listening" : statusLabel
    }

    /// Minimized: the orb (it shows listening and thinking) and what Hark is doing.
    private var pill: some View {
        HStack(spacing: 8) {
            LiveOrb(meter: engine.meter, mood: engine.phase.mood, size: 22)
            Text(pillText.count > 46 ? pillText.prefix(45).trimmingCharacters(in: .whitespaces) + "…" : pillText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
            smallButton("arrow.up.left.and.arrow.down.right", help: "Expand") { layout.setMinimized(false) }
        }
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .frame(height: 38)
        .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(Color.black.opacity(0.6))))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .contentShape(Capsule())
        .gesture(moveGesture)
        .onTapGesture(count: 2) { layout.setMinimized(false) }
        .padding(.top, 4)
    }

    private func smallButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var closeButton: some View {
        Button(action: engine.dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    private var stopButton: some View {
        Button(action: engine.stopEverything) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.16)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Stop")
    }
}

struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                switch step.status {
                case .pending:
                    Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1.2).frame(width: 14, height: 14)
                case .running:
                    ProgressView().controlSize(.mini).tint(.white).frame(width: 14, height: 14)
                case .done:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                case .failed:
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.red)
                }
            }
            .frame(width: 16)
            Text(step.title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(step.status == .pending ? 0.5 : 0.88))
                .lineLimit(1)
        }
    }
}

@MainActor
final class HUDLayout: ObservableObject {
    private(set) var size: CGSize = .zero
    var onResize: (CGSize) -> Void = { _ in }
    var onDrag: (_ ended: Bool) -> Void = { _ in }
    var onResetPosition: () -> Void = {}
    /// Minimized to a small pill; remembered across launches.
    @Published private(set) var minimized = UserDefaults.standard.bool(forKey: "HUDMinimized")

    func setMinimized(_ value: Bool) {
        minimized = value
        UserDefaults.standard.set(value, forKey: "HUDMinimized")
    }

    /// For snapshots: show a state without saving it.
    func preview(minimized: Bool) { self.minimized = minimized }

    func update(_ newSize: CGSize) {
        guard newSize != size, newSize.width > 0 else { return }
        size = newSize
        onResize(newSize)
    }
}

/// Hugs its content up to `maxHeight`, then scrolls, so the island never truncates text.
struct FittedScroll<Content: View>: View {
    let maxHeight: CGFloat
    var pinToBottom = false
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    content.fixedSize(horizontal: false, vertical: true)
                    Color.clear.frame(height: 0).id("end")
                }
                .background(GeometryReader { proxy in Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height) })
            }
            .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
            .frame(height: min(max(contentHeight, 1), maxHeight))
            .onPreferenceChange(ContentHeightKey.self) { height in
                contentHeight = height
                if pinToBottom, height > maxHeight { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct IslandSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Buttons in a non-activating panel should work on the first click.
final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
