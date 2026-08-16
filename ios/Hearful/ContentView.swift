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
            HearfulShortcuts.updateAppShortcutParameters()
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
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 24) {
                // The whole area is one button rather than a tap gesture over
                // a plain stack. Visually identical — she can still tap
                // anywhere without aiming, which is the point — but it is now
                // a control VoiceOver can find and describe, instead of an
                // invisible gesture sitting on top of some text.
                Button {
                    Task { await controller.beginCommand() }
                } label: {
                    VStack(spacing: 24) {
                        Image(systemName: icon)
                            .font(.system(size: 96))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(caption)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask Hearful")
                .accessibilityValue(caption)
                .accessibilityHint("Double tap to ask for something to listen to")

                // Only when listening has actually been refused: the trip to
                // Settings is otherwise a hunt through someone else's app.
                // Outside the button above, so it is reachable on its own.
                if controller.needsPermission {
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else {
                            return
                        }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(
                        "Opens Hearful's settings, where you can turn on the microphone")
                    .padding(.bottom, 32)
                }
            }
            .padding(.top, 40)
            // Read before the close button, which sits higher up the screen
            // and would otherwise be reached first. Landing on "Close" while
            // the screen says "double tap to speak" makes the instruction a
            // trap: the obvious gesture does the opposite of what it says.
            .accessibilitySortPriority(1)

            // The same reasoning as the player: a sheet you can open and not
            // close is worse than one you cannot open. Swiping it away has no
            // discoverable VoiceOver equivalent.
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityHint("Closes without asking for anything")
            // Last, deliberately. It is the escape hatch, not the purpose of
            // the screen, and the purpose should be what she meets first.
            .accessibilitySortPriority(0)
            .padding(.trailing, 8)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: controller.state) { _, state in
            // Once something is playing, the sheet has done its job.
            if case .playing = state { dismiss() }
        }
        // Closing the sheet is a change of mind, and it must reach the
        // microphone. Nothing here stops on its own: the recogniser would go
        // on listening to an empty room and then announce, seconds later and
        // over whatever she is doing by then, that it did not hear anything.
        //
        // On disappear rather than in the close button, because swiping the
        // sheet away is the other half of how it gets closed.
        .onDisappear { controller.cancel() }
        // Reaching this screen at all means she wants to say something: making
        // her find and tap it again is a step with no purpose.
        //
        // Except under VoiceOver, where it is the opposite. VoiceOver announces
        // the sheet the instant it appears, and nobody speaks over their own
        // screen reader — so she waits for it to finish, and the listening
        // window closes on silence before she has said a word. VoiceOver's own
        // model is focus-then-activate, and the button is the first thing she
        // lands on, so let her start it.
        .task {
            guard !UIAccessibility.isVoiceOverRunning else { return }
            await controller.beginCommand()
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
            // "Tap anywhere" is right when a tap is what starts it. Under
            // VoiceOver the gesture is a double tap on the focused control,
            // and telling her to tap anywhere would be telling her to do the
            // one thing VoiceOver has taken away.
            controller.lastSpokenResponse.isEmpty
                ? (UIAccessibility.isVoiceOverRunning
                    ? "Double tap to say what you would like"
                    : "Tap anywhere and say what you would like")
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
        let api = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)
        return VoiceController(
            api: api,
            speech: canned.map(CannedSpeechRecognizer.init(transcript:)) ?? speech,
            speaker: Speaker(),
            player: PlaybackCoordinator.shared,
            feedback: Feedback.shared,
            telemetry: TelemetryReporter(api: api))
    }
}

#Preview {
    ContentView()
}
