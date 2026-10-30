import HarkCore
import SwiftUI

struct WelcomePage: View {
    @EnvironmentObject var engine: HarkEngine
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var nav: NavigationModel

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                LiveOrb(meter: engine.meter, mood: engine.phase.mood, size: 120)
                    .padding(.top, 40)
                VStack(spacing: 10) {
                    Text("Your Mac, by voice.")
                        .font(.system(size: 34, weight: .bold))
                    Text("Hold ⌥ ⌘ and say what you want — “open Chrome, new tab, search for flights to Goa.”\nHark hears you, does it, and talks back. Everything runs on this Mac.")
                        .font(.system(size: 14.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 10) {
                    PermissionRow(title: "Microphone", detail: "Hears you only while you hold the keys.", symbol: "mic.fill", tint: .red,
                                  state: permissions.microphone, action: permissions.requestMicrophone)
                    PermissionRow(title: "Accessibility", detail: "Notices ⌥⌘, types, clicks, and reads the front window.", symbol: "accessibility", tint: .blue,
                                  state: permissions.accessibility, action: permissions.requestAccessibility)
                    PermissionRow(title: "Screen Recording", detail: "Optional. Reads text in apps that hide it from Accessibility.", symbol: "rectangle.dashed.badge.record", tint: .purple,
                                  state: permissions.screenRecording, action: permissions.requestScreenRecording)
                    PermissionRow(title: "Automation", detail: "Controls Chrome, Safari, and System Events. Asked on first use.", symbol: "gearshape.2.fill", tint: .gray,
                                  state: permissions.automation, action: permissions.requestAutomation)
                }
                .frame(maxWidth: 560)
                Button {
                    engine.settings.onboardingDone = true
                    nav.page = .home
                } label: {
                    Text(permissions.essentialsGranted ? "Start using Hark" : "Continue — grant later")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 240, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                Text("Speech is recognized on your Mac. Requests that need thinking go to Claude through the Claude Code you're signed in to.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let state: Permissions.State
    let action: () -> Void

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                switch state {
                case .granted:
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.green)
                case .denied:
                    Button("Open Settings", action: action).controlSize(.regular)
                case .unknown:
                    Button("Allow", action: action).buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
        }
    }
}

struct HomePage: View {
    @EnvironmentObject var engine: HarkEngine
    @EnvironmentObject var scheduler: Scheduler
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var nav: NavigationModel
    @State private var typed = ""

    private let examples: [(String, String)] = [
        ("safari.fill", "Open Chrome, new tab, search for best ramen in Tokyo"),
        ("terminal.fill", "Tell Claude to run the tests and fix what fails"),
        ("eye.fill", "If something changes here, click Yes"),
        ("calendar.badge.clock", "Every day at 9am open Gmail and my calendar"),
        ("doc.text.magnifyingglass", "Summarize this page"),
        ("speaker.wave.2.fill", "Set the volume to 30 percent and play music"),
    ]

    var body: some View {
        PageScaffold(title: "Good \(greeting).") {
            if !permissions.essentialsGranted {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Finish setup").font(.system(size: 13.5, weight: .semibold))
                            Text("Hark needs Microphone and Accessibility access to hear ⌥⌘ and act.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Set Up") { nav.page = .welcome }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
            }

            hero

            HStack(spacing: 12) {
                StatusTile(title: "Ears", value: "Parakeet v3", state: engine.speechModel.label, color: engine.speechModel.color, symbol: "ear.fill")
                StatusTile(title: "Brain", value: "Claude \(ClaudeModels.resolved()[engine.settings.claudeModel].map(ClaudeModels.displayName) ?? engine.settings.claudeModel.capitalized)",
                           state: engine.brainAvailable ? "Ready · 0 MB" : "Install Claude Code",
                           color: engine.brainAvailable ? .green : .orange, symbol: "brain.head.profile")
                StatusTile(title: "Automations", value: scheduler.automations.isEmpty ? "None yet" : "\(scheduler.automations.count) active",
                           state: scheduler.automations.isEmpty ? "Say “every day at…”" : "Running", color: scheduler.automations.isEmpty ? .gray : .green,
                           symbol: "eye.fill")
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "Try saying")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(examples, id: \.1) { symbol, text in
                        Button { engine.handle(text: text) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: symbol).foregroundStyle(Theme.gradient).frame(width: 18)
                                Text("“\(text)”").font(.system(size: 12.5)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Run this now")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(text: "Recent")
                    Spacer()
                    if !engine.activity.isEmpty {
                        Button("Clear") { engine.clearActivity() }.buttonStyle(.link).font(.system(size: 12))
                    }
                }
                Card(padding: 0) {
                    if engine.activity.isEmpty {
                        Text("Nothing yet. Hold ⌥⌘ and say something.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .padding(18)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(engine.activity.prefix(8).enumerated()), id: \.element.id) { index, entry in
                                ActivityRow(entry: entry)
                                if index < min(engine.activity.count, 8) - 1 { Divider().padding(.leading, 46) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var hero: some View {
        Card(padding: 22) {
            HStack(spacing: 22) {
                LiveOrb(meter: engine.meter, mood: engine.phase.mood, size: 86)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Hold").font(.system(size: 20, weight: .semibold))
                        Keycap(symbol: "⌥")
                        Keycap(symbol: "⌘")
                        Text("and speak.").font(.system(size: 20, weight: .semibold))
                    }
                    Text(engine.settings.dictationEnabled
                         ? "Commands run as you say them. Hold ⌃ ⌥ instead to dictate text anywhere."
                         : "Commands run as you say them. Release to finish.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard").foregroundStyle(.secondary)
                        TextField("Or type a command and press Return", text: $typed)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .onSubmit {
                                let text = typed.trimmingCharacters(in: .whitespaces)
                                guard !text.isEmpty else { return }
                                engine.handle(text: text)
                                typed = ""
                            }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "morning" : (hour < 17 ? "afternoon" : "evening")
    }
}

struct StatusTile: View {
    let title: String
    let value: String
    let state: String
    let color: Color
    let symbol: String

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                }
                Text(value).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                StatusPill(text: state, color: color)
            }
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(entry.ok ? .green : .orange)
                .font(.system(size: 15))
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.heard).font(.system(size: 13, weight: .medium)).lineLimit(2)
                if !entry.result.isEmpty {
                    Text(entry.result).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(entry.date, style: .time).font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct CommandsPage: View {
    private let groups: [(String, String, Color, [String])] = [
        ("Apps & web", "safari.fill", .blue, [
            "Open Chrome · Quit Slack · Switch to VS Code",
            "New tab · Close tab · Go back · Reload · Next tab",
            "Search for flights to Goa · Search YouTube for lofi · Go to github.com",
            "Google this (searches what you selected) · Download this",
        ]),
        ("Typing & keys", "keyboard.fill", .teal, [
            "Type hello world, then press enter",
            "Press command shift T · Copy · Paste · Undo · Select all · Save",
            "Click the sign in button · Scroll down a bit · Go to the top",
            "Hold ⌃⌥ to dictate straight into any text field",
        ]),
        ("Your Mac", "laptopcomputer", .gray, [
            "Set the volume to 30 percent · Mute · Next song · Pause",
            "Turn on dark mode · Lock the screen · Take a screenshot",
            "Minimize · Full screen · Show desktop · What time is it?",
        ]),
        ("Reminders & automations", "alarm.fill", .orange, [
            "Remind me in 20 minutes to call Mom · Set a timer for 5 minutes",
            "In 10 minutes, open Spotify and play music",
            "Every day at 9am open Gmail and my calendar",
            "Whenever a PDF lands in Downloads, move it to Documents",
        ]),
        ("Watch the screen", "eye.fill", .purple, [
            "Point at something and say “if this changes, click Yes”",
            "Whenever “hello” appears in Notes, say OK",
            "When I write urgent anywhere, alert me · Stop watching",
        ]),
        ("Claude Code", "terminal.fill", Color(red: 0.85, green: 0.47, blue: 0.34), [
            "Tell Claude to run the tests and fix whatever fails",
            "Ask Claude to explain this error",
        ]),
        ("Anything else", "sparkles", .purple, [
            "Summarize this page · What's on my screen?",
            "Find me a cheap flight to Goa next Friday",
            "Write an email to Priya saying I'll be late",
        ]),
    ]

    var body: some View {
        PageScaffold(title: "What to Say",
                     subtitle: "Simple commands run instantly on-device. Anything else goes to the local brain, which can look at your screen and chain steps. Chain commands with “then” or “and”.") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(groups, id: \.0) { title, symbol, tint, lines in
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: symbol)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
                                Text(title).font(.system(size: 14, weight: .semibold))
                            }
                            ForEach(lines, id: \.self) { line in
                                Text(line).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}
