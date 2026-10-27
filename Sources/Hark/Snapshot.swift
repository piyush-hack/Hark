import AppKit
import HarkCore
import SwiftUI

/// `Hark --snapshot <dir>` renders every page and island state to PNGs, then quits.
/// Used for docs and design review; needs no permissions.
@MainActor
enum Snapshot {
    static func run(into directory: URL, engine: HarkEngine, permissions: Permissions) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nav = NavigationModel.shared

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for page in [Page.welcome, .home, .commands, .automations, .intelligence, .voice, .permissions] {
                nav.page = page
                let root = MainView()
                    .environmentObject(engine).environmentObject(engine.scheduler)
                    .environmentObject(permissions).environmentObject(nav)
                render(root, size: NSSize(width: 980, height: 660), appearance: appearance,
                       to: directory.appendingPathComponent("page-\(page.rawValue)-\(suffix).png"))
            }
        }

        let states: [(String, () -> Void)] = [
            ("listening", { engine.preview(phase: .listening, transcript: "Open Chrome, open a new tab and search for the best ramen in", level: 0.7) }),
            ("working", { engine.preview(phase: .working, transcript: "Open Chrome, open a new tab and search for the best ramen in Tokyo",
                                         steps: [Step(title: "Open Google Chrome", status: .done), Step(title: "New tab", status: .done),
                                                 Step(title: "Search “the best ramen in Tokyo”", status: .running)]) }),
            ("thinking", { engine.preview(phase: .thinking, transcript: "Find me a cheap flight to Goa next Friday",
                                          steps: [Step(title: "Search “cheap flights to Goa next Friday”", status: .done),
                                                  Step(title: "Look at the screen", status: .running)]) }),
            ("answer", { engine.preview(phase: .idle, transcript: "Find me a cheap flight to Goa next Friday",
                                        steps: [Step(title: "Search “cheap flights to Goa next Friday”", status: .done),
                                                Step(title: "Look at the screen", status: .done)],
                                        reply: "The cheapest is IndiGo at ₹4,210, leaving 6:05 AM Friday.") }),
            ("long-answer", { engine.preview(phase: .idle, transcript: "What's in this section?",
                                             reply: (1...14).map { "Paragraph \($0): this answer is long on purpose, so the island has to scroll instead of cutting the text off with an ellipsis." }.joined(separator: "\n\n")) }),
            ("confirm", { engine.preview(phase: .idle, transcript: "Delete the build folder",
                                         confirmation: "Run this command? rm -rf ./build") }),
            ("dictation", { engine.preview(phase: .listening, mode: .dictation, transcript: "Hey Priya, running ten minutes late — start without me.", level: 0.5) }),
        ]
        for (name, apply) in states + [("minimized", { engine.preview(phase: .thinking, transcript: "Apply to five jobs") })] {
            apply()
            let layout = HUDLayout()
            layout.preview(minimized: name == "minimized")
            let island = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.36), Color(red: 0.45, green: 0.38, blue: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                HUDView().environmentObject(engine).environmentObject(layout)
            }
            render(island, size: HUDController.size, appearance: .darkAqua,
                   to: directory.appendingPathComponent("island-\(name).png"))
        }
        engine.preview(phase: .idle)
        print("Snapshots written to \(directory.path)")
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
