import SwiftUI

/// Opens the voice sheet, with a tick of haptic feedback standing in for the
/// sheet sliding up — the one part of tapping the microphone she cannot see.
/// The sheet starts listening on its own once it is there.
@MainActor
func openVoiceSheet(_ showingVoice: Binding<Bool>) {
    Feedback.shared.play(.opened)
    showingVoice.wrappedValue = true
}

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
        .task {
            // The Ask Hearful intent may have run before this view existed.
            if VoicePrompt.consume() {
                showingVoice = true
            }
            await PlaybackRestore.restore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hearfulAskByVoice)) { _ in
            _ = VoicePrompt.consume()
            showingVoice = true
        }
        // Subscribing in the app (or by voice) changes which show names Siri
        // should recognise in phrases; tell it to refetch them.
        .onReceive(NotificationCenter.default.publisher(for: .hearfulSubscriptionsChanged)) { _ in
            Task { await HearfulShortcuts.updateAppShortcutParameters() }
        }
    }
}

/// Voice is now one way in among several, so it lives in a sheet rather than
/// being the whole screen. Opening it is itself the request to speak, so it
/// listens straight away; tapping it again asks for the next thing.
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
            // Only when listening has actually been refused: the trip to
            // Settings is otherwise a hunt through someone else's app.
            if controller.needsPermission {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens Hearful's settings, where you can turn on the microphone")
            }
            Spacer()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { Task { await controller.beginCommand() } }
        // Combined into one target normally, so a tap anywhere speaks — but
        // not when there is a button to reach: merging would bury it.
        .accessibilityElement(children: controller.needsPermission ? .contain : .combine)
        .accessibilityLabel("Ask Hearful")
        .accessibilityValue(caption)
        .accessibilityHint("Double tap anywhere to ask for something to listen to")
        .accessibilityAddTraits(.isButton)
        .onChange(of: controller.state) { _, state in
            // Once something is playing, the sheet has done its job.
            if case .playing = state { dismiss() }
        }
        // Reaching this screen at all means she wants to say something: making
        // her find and tap it again is a step with no purpose.
        .task { await controller.beginCommand() }
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
            feedback: Feedback.shared)
    }
}

#Preview {
    ContentView()
}
