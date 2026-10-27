import HarkCore
import SwiftUI

enum Theme {
    static let spectrum: [Color] = [
        Color(red: 0.00, green: 0.78, blue: 1.00),
        Color(red: 0.37, green: 0.36, blue: 0.90),
        Color(red: 0.75, green: 0.35, blue: 0.95),
        Color(red: 1.00, green: 0.22, blue: 0.37),
        Color(red: 1.00, green: 0.62, blue: 0.04),
    ]
    static let accent = Color(red: 0.37, green: 0.36, blue: 0.90)
    static let gradient = LinearGradient(colors: [spectrum[0], spectrum[1], spectrum[2]], startPoint: .topLeading, endPoint: .bottomTrailing)
}

enum OrbMood: Equatable { case idle, listening, thinking, working, announcing }

extension EnginePhase {
    var mood: OrbMood {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .transcribing, .thinking: return .thinking
        case .working: return .working
        case .announcing: return .announcing
        }
    }
}

/// A living sphere of light: drifts when idle, swells with your voice, swirls while thinking.
struct OrbView: View {
    var level: CGFloat = 0
    var mood: OrbMood = .idle
    var size: CGFloat = 40

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: mood == .idle)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed: Double = mood == .thinking ? 2.6 : (mood == .working ? 1.8 : (mood == .listening ? 1.2 : 0.5))
            let energy = mood == .listening ? Double(level) : (mood == .idle ? 0.05 : 0.35)
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(red: 0.10, green: 0.08, blue: 0.22), Color(red: 0.02, green: 0.02, blue: 0.06)],
                                             center: .center, startRadius: 0, endRadius: size * 0.6))
                ForEach(0..<5, id: \.self) { i in
                    let phase = t * speed * (0.6 + Double(i) * 0.17) + Double(i) * 1.26
                    Circle()
                        .fill(Theme.spectrum[i])
                        .frame(width: size * (0.72 + 0.12 * energy), height: size * (0.72 + 0.12 * energy))
                        .offset(x: cos(phase) * size * (0.2 + 0.08 * energy), y: sin(phase * 1.13) * size * (0.2 + 0.08 * energy))
                        .blur(radius: size * 0.16)
                        .blendMode(.plusLighter)
                        .opacity(0.78)
                }
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.18 + 0.5 * energy), .clear], center: .center, startRadius: 0, endRadius: size * 0.22))
                    .blendMode(.plusLighter)
                Circle()
                    .fill(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center))
                    .frame(width: size * 0.78, height: size * 0.5)
                    .offset(y: -size * 0.2)
                    .blur(radius: size * 0.03)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .scaleEffect(1 + 0.12 * energy)
            .shadow(color: Theme.spectrum[1].opacity(0.25 + 0.35 * energy), radius: size * 0.25)
        }
        .frame(width: size, height: size)
    }
}

/// An orb that follows the microphone without making its parent view redraw.
struct LiveOrb: View {
    @ObservedObject var meter: AudioLevel
    var mood: OrbMood
    var size: CGFloat

    var body: some View { OrbView(level: CGFloat(meter.value), mood: mood, size: size) }
}

struct Keycap: View {
    let symbol: String
    var dark = false

    var body: some View {
        Text(symbol)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(dark ? .white.opacity(0.9) : .primary)
            .frame(minWidth: 26, minHeight: 24)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(dark ? AnyShapeStyle(.white.opacity(0.1)) : AnyShapeStyle(.background))
                    .shadow(color: .black.opacity(dark ? 0 : 0.12), radius: 0.5, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    }
}
