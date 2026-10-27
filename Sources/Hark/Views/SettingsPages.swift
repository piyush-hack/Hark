import HarkCore
import SwiftUI

struct AutomationsPage: View {
    @EnvironmentObject var scheduler: Scheduler
    @State private var when = ""
    @State private var task = ""
    @State private var reminder = false
    @State private var error: String?

    var body: some View {
        PageScaffold(title: "Automations",
                     subtitle: "Hark wakes its brain only when one of these fires. Create them by voice (“every day at 9am…”) or here.") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("New automation").font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 10) {
                        TextField("When — in 10 minutes, at 6pm, every day at 9am, every 30 minutes", text: $when)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Just remind me", isOn: $reminder).toggleStyle(.checkbox).fixedSize()
                    }
                    HStack(spacing: 10) {
                        TextField(reminder ? "What to say" : "What to do — e.g. open Gmail and my calendar", text: $task)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(add)
                        Button("Add", action: add).buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(when.isEmpty || task.isEmpty)
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                }
            }

            SectionHeader(text: scheduler.automations.isEmpty ? "Nothing scheduled" : "Scheduled")
            if !scheduler.automations.isEmpty {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(scheduler.automations.enumerated()), id: \.element.id) { index, automation in
                            AutomationRow(automation: automation) { scheduler.remove(automation.id) }
                            if index < scheduler.automations.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        guard let trigger = Scheduler.trigger(from: when) else {
            error = "I couldn't understand “\(when)”. Try “in 15 minutes”, “at 6pm”, or “every day at 9am”."
            return
        }
        scheduler.add(Automation(trigger: trigger, task: task, reminder: reminder, createdBy: "you"))
        when = ""; task = ""; error = nil
    }
}

struct AutomationRow: View {
    let automation: Automation
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.orange.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text(automation.task).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(automation.summary.components(separatedBy: " — ").last ?? "")
                    if let next = automation.nextRun() {
                        Text("·")
                        Text(next, style: .relative)
                    }
                    Text("· by \(automation.createdBy)")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var icon: String {
        switch automation.trigger {
        case .once: return automation.reminder ? "alarm.fill" : "clock.fill"
        case .daily: return "sun.max.fill"
        case .every: return "repeat"
        case .newFile: return "folder.fill"
        case .appLaunch: return "app.badge.fill"
        case .textAppears, .screenWatch: return "eye.fill"
        }
    }
}

struct IntelligencePage: View {
    @EnvironmentObject var engine: HarkEngine

    var body: some View {
        PageScaffold(title: "Intelligence",
                     subtitle: "Ears on your Mac, brain in Claude. Nothing sits in memory while you're not talking.") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Ears — Parakeet TDT 0.6B v3", systemImage: "ear.fill").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        StatusPill(text: engine.speechModel.label, color: engine.speechModel.color)
                    }
                    Text("Runs on the Neural Engine with Apple's voice isolation in front of it. About 1 second to transcribe a sentence; about 0.9 GB while awake.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("Sleep after", selection: $engine.settings.speechIdleUnload) {
                        Text("Never — always instant (recommended)").tag(Int.max / 2)
                        Text("3 minutes idle").tag(180)
                        Text("15 minutes idle").tag(900)
                        Text("1 hour idle").tag(3600)
                    }
                    .frame(maxWidth: 320)
                    Toggle("Noise suppression (Apple voice processing)", isOn: $engine.settings.noiseSuppression)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Brain — Claude, through your Claude Code sign-in", systemImage: "brain.head.profile")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        StatusPill(text: engine.brainAvailable ? "Ready · 0 MB" : "Not installed", color: engine.brainAvailable ? .green : .orange)
                    }
                    if engine.brainAvailable {
                        Text("Simple commands run instantly on your Mac. Everything else goes to Claude — no API key, no extra cost, about 3 seconds. Claude sees your request, the front app, and Hark's tools, and replies with a plan Hark carries out.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Picker("Model", selection: $engine.settings.claudeModel) {
                            Text("Haiku — fastest").tag("haiku")
                            Text("Sonnet — smartest").tag("sonnet")
                        }
                        .frame(maxWidth: 320)
                        Text("Uses your Claude plan's usage. Requests and any screen or page text they need are sent to Anthropic.")
                            .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    } else {
                        Text("Install Claude Code (claude.com/claude-code) and sign in with your Claude account. Until then, only instant commands work.")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $engine.settings.autoApprove) {
                        Label("Auto-approve sensitive actions", systemImage: "checkmark.shield.fill").font(.system(size: 14, weight: .semibold))
                    }
                    .toggleStyle(.switch)
                    Text(engine.settings.autoApprove
                         ? "On: sending, deleting, buying, submitting, and risky shell commands run without asking."
                         : "Off: Hark asks first — say yes or no (it listens right away), or click. “Yes, don't ask again” approves everything until Hark quits.")
                        .font(.system(size: 12)).foregroundStyle(engine.settings.autoApprove ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await engine.refreshModelStatus() }
    }
}

struct VocabularyCard: View {
    @EnvironmentObject var engine: HarkEngine
    @State private var newWord = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Words Hark should know").font(.system(size: 13.5, weight: .semibold))
                Text("Names, brands, and sites the speech model mishears. Hark fixes them by how they sound — “bijoyus” becomes bejoyous.ai.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                FlowWords(words: engine.settings.vocabulary) { word in engine.settings.vocabulary.removeAll { $0 == word } }
                TextField("Add a word or name, then press Return", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let word = newWord.trimmingCharacters(in: .whitespaces)
                        if !word.isEmpty, !engine.settings.vocabulary.contains(word) { engine.settings.vocabulary.append(word) }
                        newWord = ""
                    }
                Divider()
                Picker("Speech engine", selection: $engine.settings.speechEngine) {
                    Text("Parakeet — most accurate in noise").tag("parakeet")
                    Text("Apple English (India) — fastest, learns your words").tag("apple")
                }
                .frame(maxWidth: 440)
                .onChange(of: engine.settings.speechEngine) { engineName in
                    if engineName == "apple" { Task { _ = await AppleTranscriber.requestPermission() } }
                }
                if engine.settings.speechEngine == "parakeet" {
                    Toggle("English-only model (turn off for 25 European languages)", isOn: $engine.settings.englishSpeechModel)
                }
                Toggle("Keep my last 20 commands' audio on this Mac to tune recognition to my voice", isOn: $engine.settings.keepRecordings)
                Text("Saved only in ~/Library/Application Support/Hark/recordings. Turn off to stop; delete the folder anytime.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct FlowWords: View {
    let words: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(words, id: \.self) { word in
                HStack(spacing: 4) {
                    Text(word).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Button { onRemove(word) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
            }
        }
    }
}

struct VoicePage: View {
    @EnvironmentObject var engine: HarkEngine

    var body: some View {
        PageScaffold(title: "Speech & Sound", subtitle: "How Hark hears you, and how it gets your attention. Answers show up as text on the island — Hark never talks.") {
            VocabularyCard()
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Tick-tick when Hark needs you", isOn: $engine.settings.attentionSound)
                    Picker("Repeat", selection: $engine.settings.attentionInterval) {
                        Text("Every 5 seconds").tag(5)
                        Text("Every 10 seconds").tag(10)
                        Text("Every 20 seconds").tag(20)
                        Text("Every 30 seconds").tag(30)
                        Text("Every minute").tag(60)
                        Text("Only once").tag(0)
                    }
                    .frame(maxWidth: 300)
                    .disabled(!engine.settings.attentionSound)
                    Text("Ticks when a request finishes, Hark asks you something, or a reminder or alert arrives. Long tasks, Claude's answers, questions, and alerts repeat until you look at the island, press ⌥⌘, speak, or tap the bell on the island to mute that one. Quick commands tick once.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle("Hold ⌃⌥ to dictate text", isOn: $engine.settings.dictationEnabled)
                }
            }
        }
    }
}

struct PermissionsPage: View {
    @EnvironmentObject var permissions: Permissions

    var body: some View {
        PageScaffold(title: "Permissions", subtitle: "macOS asks once for each. You can change them any time in System Settings → Privacy & Security.") {
            VStack(spacing: 10) {
                PermissionRow(title: "Microphone", detail: "Only while ⌥⌘ or ⌃⌥ is held. The orange dot shows when.", symbol: "mic.fill", tint: .red,
                              state: permissions.microphone, action: permissions.requestMicrophone)
                PermissionRow(title: "Accessibility", detail: "Hotkeys, typing, clicking, and reading the front window.", symbol: "accessibility", tint: .blue,
                              state: permissions.accessibility, action: permissions.requestAccessibility)
                PermissionRow(title: "Screen Recording", detail: "Lets “if this changes” watchers see visual changes, and reads text in apps that hide it.", symbol: "rectangle.dashed.badge.record", tint: .purple,
                              state: permissions.screenRecording, action: permissions.requestScreenRecording)
                PermissionRow(title: "Automation", detail: "Chrome, Safari, Terminal, System Events — asked the first time each is used.", symbol: "gearshape.2.fill", tint: .gray,
                              state: permissions.automation, action: permissions.requestAutomation)
                PermissionRow(title: "Full Disk Access", detail: "Optional. Lets Hark and the commands it runs read Documents, Desktop, and Downloads without a prompt for each folder.", symbol: "folder.fill", tint: .teal,
                              state: permissions.fullDiskAccess, action: permissions.requestFullDiskAccess)
            }
            Text("Tip: in Chrome, View → Developer → Allow JavaScript from Apple Events lets Hark read pages for “summarize this page”.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct AboutPage: View {
    @EnvironmentObject var engine: HarkEngine

    var body: some View {
        PageScaffold(title: "About Hark") {
            Card {
                HStack(spacing: 18) {
                    OrbView(mood: .idle, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hark").font(.system(size: 22, weight: .bold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · MIT License")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        Text("A voice agent for macOS.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automation link").font(.system(size: 14, weight: .semibold))
                    Text("Run commands from Shortcuts, Raycast, or scripts. Keep the key private — anyone with it can drive your Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Text("hark://run?key=\(engine.settings.urlKey)&text=open%20chrome")
                            .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        Spacer()
                        Button("New Key") { engine.settings.urlKey = HarkSettings.newKey() }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Privacy").font(.system(size: 14, weight: .semibold))
                    Text("Audio is processed in memory and never saved; speech recognition (Parakeet via FluidAudio) runs on this Mac. Requests that need thinking go to Claude through your Claude Code sign-in, with the screen or page text they need. Hark sends nothing else.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Built on FluidAudio (Apache 2.0), NVIDIA Parakeet (CC-BY-4.0), Silero VAD (MIT), and Claude Code.")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
