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
                        ModelPicker(title: "Brain", selection: $engine.settings.claudeModel)
                        ModelPicker(title: "Writing", selection: $engine.settings.writerModel)
                        Text("The brain plans actions from the screen; the writing model turns speech into text edits — keep it fast.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Text("Uses your Claude plan's usage. Requests and any screen or page text they need are sent to Anthropic.")
                            .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    } else {
                        Text("Install Claude Code (claude.com/claude-code) and sign in with your Claude account. Until then, only instant commands work.")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
            }
            LearnedCard(book: engine.lessonBook)
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
                Toggle("Keep my last 20 commands' audio for troubleshooting", isOn: $engine.settings.keepRecordings)
                Text("Saves the audio and what Hark heard, so misheard commands can be replayed and checked. It doesn't train anything. Only on this Mac, in ~/Library/Application Support/Hark/recordings; turn off to stop, delete the folder anytime.")
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
        PageScaffold(title: "Speech", subtitle: "How Hark hears you. Answers show up as text on the island, with one soft tick-tick when something's done.") {
            VoiceMatchCard()
            VocabularyCard()
            Card {
                Toggle("Hold ⌃⌥ to dictate text", isOn: $engine.settings.dictationEnabled)
            }
        }
    }
}

/// Every Claude model your Claude Code sign-in offers (newest of each family), or any exact model name.
struct ModelPicker: View {
    let title: String
    @Binding var selection: String
    @State private var names = ClaudeModels.resolved()
    @State private var custom = ""

    private var isCustom: Bool { !ClaudeModels.all.contains { $0.id == selection } }

    var body: some View {
        HStack(spacing: 10) {
            Picker(title, selection: Binding(get: { isCustom ? "custom" : selection },
                                             set: { selection = $0 == "custom" ? (custom.isEmpty ? selection : custom) : $0 })) {
                ForEach(ClaudeModels.all) { option in
                    Text("\(names[option.id].map(ClaudeModels.displayName) ?? option.family) — \(option.detail)").tag(option.id)
                }
                Divider()
                Text("Exact model name…").tag("custom")
            }
            .frame(maxWidth: 380)
            if isCustom {
                TextField("claude-…", text: Binding(get: { selection }, set: { selection = $0.trimmingCharacters(in: .whitespaces) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
            }
        }
        .task { names = await ClaudeModels.refresh() }
    }
}

/// What Hark has learned by doing — each how-to was confirmed on screen before it was saved.
struct LearnedCard: View {
    @ObservedObject var book: LessonBook

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("What Hark has learned", systemImage: "graduationcap.fill").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if !book.lessons.isEmpty { Button("Forget all") { book.forgetAll() }.controlSize(.small) }
                }
                Text(book.lessons.isEmpty
                     ? "When Claude works out how to do something (a button to click, a shortcut that works) and sees it worked, Hark remembers the how-to and goes straight to it next time."
                     : "Saved only after the result was checked on screen. Used for similar requests in the same app or site; dropped after it fails twice.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(book.lessons.sorted { $0.lastUsed > $1.lastUsed }) { lesson in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lesson.task.prefix(1).uppercased() + lesson.task.dropFirst()).font(.system(size: 12.5, weight: .semibold))
                            Text(lesson.how).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text([lesson.site.isEmpty ? lesson.app : lesson.site, "worked \(lesson.successes)×"].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button { book.forget(lesson.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Forget this")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

struct VoiceMatchCard: View {
    @EnvironmentObject var engine: HarkEngine

    private var ready: Bool { engine.voiceSamples >= VoiceID.samplesNeeded }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle(isOn: $engine.settings.voiceMatch) {
                        Label("Only obey my voice in hands-free", systemImage: "person.wave.2.fill").font(.system(size: 14, weight: .semibold))
                    }
                    .toggleStyle(.switch)
                    Spacer()
                    if engine.settings.voiceMatch {
                        StatusPill(text: ready ? "Knows your voice" : "Learning \(engine.voiceSamples)/\(VoiceID.samplesNeeded)",
                                   color: ready ? .green : .orange)
                    }
                }
                Text(ready
                     ? "In hands-free, people talking near you are ignored. Hark keeps learning your voice whenever you hold ⌥⌘, so a cold or a new mic is fine. Everything stays on this Mac."
                     : "Hark learns your voice from what you say while holding ⌥⌘ — or teach it now in about 15 seconds. Until then, hands-free listens to everyone.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(engine.learningVoice ? "Listening — keep talking…" : (ready ? "Teach it again" : "Teach my voice")) { engine.learnVoice() }
                        .disabled(engine.learningVoice || !engine.settings.voiceMatch)
                    if engine.voiceSamples > 0 {
                        Button("Forget my voice") { engine.forgetVoice() }
                    }
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
    @EnvironmentObject var updater: Updater

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
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Updates").font(.system(size: 14, weight: .semibold))
                            Text(updateStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if updater.phase == .checking { ProgressView().controlSize(.small) }
                        Button(updater.release == nil ? "Check Now" : "Update…", action: updater.checkNow).disabled(updater.isWorking)
                    }
                    Toggle("Check for updates automatically", isOn: $engine.settings.checkForUpdates)
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
                    Text("Audio is processed in memory and never saved; speech recognition (Parakeet via FluidAudio) runs on this Mac. Requests that need thinking go to Claude through your Claude Code sign-in, with the screen or page text they need. Update checks ask GitHub for the newest version number. Hark sends nothing else.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Built on FluidAudio (Apache 2.0), NVIDIA Parakeet (CC-BY-4.0), Silero VAD (MIT), and Claude Code.")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension AboutPage {
    var updateStatus: String {
        if let release = updater.release { return "Hark \(release.version) is available — you have \(updater.current)." }
        switch updater.phase {
        case .checking: return "Checking…"
        case .upToDate: return "You're up to date."
        default: return engine.settings.checkForUpdates ? "Hark looks for a new version at launch and every few hours." : "Automatic checks are off."
        }
    }
}
