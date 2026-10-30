import HarkCore
import SwiftUI

/// The "a new version is available" window: what changed, then install in place and reopen.
struct UpdateView: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let release = updater.release, !release.notes.isEmpty {
                ScrollView {
                    Text(ReleaseNotes.attributed(release.notes))
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            }
            status
            buttons
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 460)
        .animation(.easeOut(duration: 0.15), value: updater.phase)
    }

    private var title: String {
        if updater.release != nil { return "A new version of Hark is available" }
        switch updater.phase {
        case .checking: return "Checking for updates…"
        case .failed: return "Couldn't check for updates"
        default: return "You're up to date"
        }
    }

    private var subtitle: String {
        if let release = updater.release { return "Hark \(release.version) is ready — you have \(updater.current)." }
        switch updater.phase {
        case .checking: return "Asking GitHub for the newest version of Hark."
        case .failed(let message): return message
        default: return "Hark \(updater.current) is the newest version."
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction).tint(Theme.accent)
                Text(downloadText(fraction)).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing — Hark will reopen in a moment.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .failed(let message) where updater.release != nil:
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .available where !updater.canInstall:
            Text(cannotInstallReason).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch updater.phase {
            case .checking:
                ProgressView().controlSize(.small)
                Spacer()
                Button("Cancel", action: updater.later)
            case .downloading, .installing:
                Spacer()
                Button("Cancel", action: updater.later).disabled(updater.phase == .installing)
            case .failed where updater.release == nil:
                Spacer()
                Button("Try Again", action: updater.checkNow)
                Button("OK", action: updater.later).keyboardShortcut(.defaultAction)
            case .available, .failed:
                Button("Skip This Version", action: updater.skip)
                Spacer()
                Button("Remind Me Later", action: updater.later)
                if updater.canInstall {
                    Button(updater.phase == .available ? "Install and Relaunch" : "Try Again", action: updater.install)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Download…") {
                        updater.openReleasePage()
                        updater.later()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            default:
                Spacer()
                Button("OK", action: updater.later).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func downloadText(_ fraction: Double) -> String {
        guard let size = updater.release?.archiveSize, size > 0 else { return "Downloading… \(Int(fraction * 100))%" }
        let total = Double(size) / 1_000_000
        return String(format: "Downloading… %.1f of %.1f MB", total * fraction, total)
    }

    private var cannotInstallReason: String {
        if updater.release?.archive == nil { return "This release has no app attached, so download it from GitHub." }
        if case .failure(let error) = UpdateInstaller.destination() { return error.message }
        return ""
    }
}

enum ReleaseNotes {
    /// GitHub release text as styled text: headings bold, list items as bullets, inline Markdown (bold, links, code) kept.
    static func attributed(_ notes: String) -> AttributedString {
        let lines = notes.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? "" : "**\(heading)**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return "•  " + trimmed.dropFirst(2) }
            return line
        }
        let text = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
