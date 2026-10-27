import HarkCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case welcome, home, commands, automations, intelligence, voice, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .home: return "Home"
        case .commands: return "What to Say"
        case .automations: return "Automations"
        case .intelligence: return "Intelligence"
        case .voice: return "Speech & Sound"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "sparkles"
        case .home: return "house.fill"
        case .commands: return "text.bubble.fill"
        case .automations: return "clock.arrow.2.circlepath"
        case .intelligence: return "cpu.fill"
        case .voice: return "waveform"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .welcome: return .purple
        case .home: return .blue
        case .commands: return .teal
        case .automations: return .orange
        case .intelligence: return .indigo
        case .voice: return .pink
        case .permissions: return .green
        case .about: return .gray
        }
    }
}

@MainActor
final class NavigationModel: ObservableObject {
    static let shared = NavigationModel()
    @Published var page: Page = .home
}

struct MainView: View {
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var engine: HarkEngine

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 228)
                .background(.ultraThinMaterial)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
            Group {
                switch nav.page {
                case .welcome: WelcomePage()
                case .home: HomePage()
                case .commands: CommandsPage()
                case .automations: AutomationsPage()
                case .intelligence: IntelligencePage()
                case .voice: VoicePage()
                case .permissions: PermissionsPage()
                case .about: AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 560)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                LiveOrb(meter: engine.meter, mood: engine.phase.mood, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Hark").font(.system(size: 16, weight: .semibold))
                    Text(engine.phase == .idle ? "Hold ⌥⌘ to talk" : "Listening…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 40)
            .padding(.bottom, 16)
            ForEach([Page.home, .commands, .automations]) { row($0) }
            Text("Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 4)
            ForEach([Page.intelligence, .voice, .permissions, .about]) { row($0) }
            Spacer()
        }
        .padding(.horizontal, 10)
    }

    private func row(_ page: Page) -> some View {
        let selected = nav.page == page || (nav.page == .welcome && page == .home)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { nav.page = page }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(page.tint.gradient))
                Text(page.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared building blocks

struct PageScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 28, weight: .bold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 13.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 40)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
    }
}

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

extension ModelState {
    var label: String {
        switch self {
        case .asleep: return "Asleep · 0 MB"
        case .loading: return "Waking up…"
        case .ready: return "Ready"
        case .unavailable: return "Unavailable"
        }
    }

    var color: Color {
        switch self {
        case .asleep: return .gray
        case .loading: return .orange
        case .ready: return .green
        case .unavailable: return .red
        }
    }
}
