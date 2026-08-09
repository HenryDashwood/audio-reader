import SwiftUI

struct ContentView: View {
    @State private var showingVoice = false
    @State private var showingNowPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                Tab("Shows", systemImage: "square.stack") {
                    LibraryView(showingVoice: $showingVoice)
                }
                Tab("Latest", systemImage: "clock") {
                    LatestView(showingVoice: $showingVoice)
                }
                Tab("Settings", systemImage: "gearshape") {
                    SettingsView()
                }
            }
            MiniPlayer(showingNowPlaying: $showingNowPlaying)
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView()
        }
        .sheet(isPresented: $showingVoice) {
            VoiceSheet()
                .presentationDetents([.medium])
        }
        .task { await PlaybackRestore.restore() }
    }
}

/// Voice is now one way in among several, so it lives in a sheet rather than
/// being the whole screen. The interaction inside is unchanged: tap, speak.
struct VoiceSheet: View {
    @StateObject private var controller = VoiceController.live()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 96))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(caption)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { Task { await controller.beginCommand() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ask Hearful")
        .accessibilityValue(caption)
        .accessibilityHint("Double tap anywhere to ask for something to listen to")
        .accessibilityAddTraits(.isButton)
        .onChange(of: controller.state) { _, state in
            // Once something is playing, the sheet has done its job.
            if case .playing = state { dismiss() }
        }
    }

    private var icon: String {
        switch controller.state {
        case .idle: "mic.circle.fill"
        case .listening: "waveform.circle.fill"
        case .thinking: "ellipsis.circle.fill"
        case .playing: "speaker.wave.2.circle.fill"
        }
    }

    private var caption: String {
        switch controller.state {
        case .idle:
            controller.lastSpokenResponse.isEmpty
                ? "Tap anywhere and say what you would like"
                : controller.lastSpokenResponse
        case .listening: "Listening…"
        case .thinking: "One moment…"
        case .playing(let episode): "Playing \(episode.title)"
        }
    }
}

extension VoiceController {
    /// The real wiring. Kept out of the initialiser so tests can inject fakes.
    @MainActor
    static func live() -> VoiceController {
        let canned = ProcessInfo.processInfo.environment["HEARFUL_FAKE_TRANSCRIPT"]
        // Prefer iOS 26's on-device analyser; fall back to the older recogniser
        // where its models are unavailable (notably the simulator).
        let speech = FallbackSpeechRecognizer(
            preferred: AnalyzerSpeechRecognizer(), backup: SpeechRecognizer())
        return VoiceController(
            api: HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
            speech: canned.map(CannedSpeechRecognizer.init(transcript:)) ?? speech,
            speaker: Speaker(),
            player: PlaybackCoordinator.shared,
            feedback: Feedback())
    }
}

#Preview {
    ContentView()
}
