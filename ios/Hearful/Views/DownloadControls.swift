import SwiftUI

/// Something to show after asking for a download by tapping. A voice request
/// asks the same questions out loud instead; see VoiceController.
enum DownloadPrompt: Identifiable {
    case confirm(DownloadConfirmation)
    case refused(String)
    case nothingToDo(String)

    var id: String {
        switch self {
        case .confirm(let confirmation): confirmation.id.uuidString
        case .refused(let message), .nothingToDo(let message): message
        }
    }
}

extension EpisodeDownloads {
    /// Starts a download from a tap, announcing it, or returns the dialog to
    /// show first.
    func requestFromTap(_ episodes: [Episode]) -> DownloadPrompt? {
        switch request(episodes) {
        case .started(let started):
            AccessibilityNotification.Announcement(Self.startedAnnouncement(started)).post()
            return nil
        case .nothingToDo(let message): return .nothingToDo(message)
        case .refused(let message): return .refused(message)
        case .needsConfirmation(let confirmation): return .confirm(confirmation)
        }
    }

    func confirmFromTap(_ confirmation: DownloadConfirmation, waitForWiFi: Bool) {
        confirm(confirmation, waitForWiFi: waitForWiFi)
        AccessibilityNotification.Announcement(
            waitForWiFi ? "Will download when you are on Wi-Fi." : Self.startedAnnouncement(confirmation.episodes)
        ).post()
    }

    static func startedAnnouncement(_ episodes: [Episode]) -> String {
        episodes.count == 1 ? "Downloading \(episodes[0].title)" : "Downloading \(episodes.count) episodes"
    }
}

extension View {
    /// The dialog for a download that needs a yes, or cannot happen.
    /// VoiceOver reads an alert as soon as it appears.
    func downloadPrompt(_ prompt: Binding<DownloadPrompt?>) -> some View {
        modifier(DownloadPromptModifier(prompt: prompt))
    }
}

private struct DownloadPromptModifier: ViewModifier {
    @Binding var prompt: DownloadPrompt?

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented, presenting: prompt) { prompt in
            switch prompt {
            case .confirm(let confirmation):
                Button(confirmation.usesMobileData ? "Download Now" : "Download Anyway") {
                    EpisodeDownloads.shared.confirmFromTap(confirmation, waitForWiFi: false)
                }
                if confirmation.usesMobileData {
                    Button("Wait for Wi-Fi") {
                        EpisodeDownloads.shared.confirmFromTap(confirmation, waitForWiFi: true)
                    }
                }
                Button("Cancel", role: .cancel) {}
            case .refused, .nothingToDo:
                Button("OK", role: .cancel) {}
            }
        } message: { prompt in
            switch prompt {
            case .confirm(let confirmation): Text(confirmation.message)
            case .refused(let message), .nothingToDo(let message): Text(message)
            }
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private var title: String {
        switch prompt {
        case .confirm(let confirmation): confirmation.title
        case .refused: "Not enough space"
        case .nothingToDo: "Nothing to download"
        case nil: ""
        }
    }
}

/// Downloads an episode, shows how it is going, and removes it again.
struct DownloadButton: View {
    let episode: Episode
    /// The capsule matches the speed and sleep controls in the full player.
    var capsule = false
    @ObservedObject private var downloads = EpisodeDownloads.shared
    @State private var prompt: DownloadPrompt?
    @State private var confirmingRemoval = false

    private var record: DownloadRecord? { downloads.record(for: episode.id) }

    var body: some View {
        Button(action: tapped) {
            label
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(record?.statusLabel ?? "")
        .accessibilityHint(hint)
        .downloadPrompt($prompt)
        .confirmationDialog(
            "Remove the download of \(episode.title)?", isPresented: $confirmingRemoval, titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                downloads.remove(episodeID: episode.id)
                AccessibilityNotification.Announcement("Download removed").post()
            }
        } message: {
            Text("You can still play it with a connection.")
        }
        // Only on arrival; removing a download is not a success to celebrate.
        .sensoryFeedback(.success, trigger: record?.status == .downloaded) { old, new in new && !old }
    }

    @ViewBuilder
    private var label: some View {
        let glyph = Group {
            switch record?.status {
            case .queued, .downloading:
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(progress, 0.03))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 8))
                }
                .frame(width: 20, height: 20)
            case .downloaded:
                Image(systemName: "arrow.down.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.arrow.circlepath")
            case nil:
                Image(systemName: "arrow.down.circle")
            }
        }
        if capsule {
            Group {
                if let record, record.status != .downloaded {
                    Label { Text(record.statusLabel) } icon: { glyph }
                } else {
                    glyph
                }
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        } else {
            glyph.frame(width: 44, height: 44)
        }
    }

    private var progress: Double {
        if case .downloading(let progress) = record?.status { progress } else { 0 }
    }

    private var accessibilityLabel: String {
        switch record?.status {
        case .queued, .downloading: "Cancel download"
        case .downloaded: "Remove download"
        case .failed: "Retry download"
        case nil: "Download"
        }
    }

    private var hint: String {
        switch record?.status {
        case .queued, .downloading: "Stops downloading this episode"
        case .downloaded: "Frees the space this episode uses on your iPhone"
        case .failed(let message): message
        case nil: "Keeps this episode on your iPhone so it plays without a connection"
        }
    }

    private func tapped() {
        switch record?.status {
        case .queued, .downloading:
            downloads.remove(episodeID: episode.id)
            AccessibilityNotification.Announcement("Download cancelled").post()
        case .downloaded:
            confirmingRemoval = true
        case .failed, nil:
            prompt = downloads.requestFromTap([episode])
        }
    }
}
