import SwiftUI

/// The whole screen is one button: there is no layout to learn and no target
/// to find. Everything meaningful is announced aloud rather than shown.
struct ContentView: View {
    @StateObject private var controller = VoiceController.live()

    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: icon)
                    .font(.system(size: 120))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(caption)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await controller.beginCommand() } }
        // One element for VoiceOver, so a swipe cannot land somewhere useless.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hearful")
        .accessibilityValue(caption)
        .accessibilityHint("Double tap anywhere to ask for something to listen to")
        .accessibilityAddTraits(.isButton)
    }

    private var icon: String {
        switch controller.state {
        case .idle: "mic.circle.fill"
        case .listening: "waveform.circle.fill"
        case .thinking: "ellipsis.circle.fill"
        case .playing: "play.circle.fill"
        }
    }

    private var caption: String {
        switch controller.state {
        case .idle:
            controller.lastSpokenResponse.isEmpty
                ? "Tap anywhere to talk" : controller.lastSpokenResponse
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
            player: AudioPlayer(),
            feedback: Feedback())
    }
}

#Preview {
    ContentView()
}
