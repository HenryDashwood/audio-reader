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
    private enum AppTab: Hashable {
        case shows
        case latest
        case settings
    }

    @EnvironmentObject private var auth: AuthController
    @State private var showingVoice = false
    @State private var showingNowPlaying = false
    @State private var selectedTab: AppTab = .shows
    @State private var lastContentTab: AppTab = .shows
    @State private var showsOpenEpisode: Episode?
    @State private var latestOpenEpisode: Episode?
    @State private var serverGeneration = 0

    @ObservedObject private var metrics = TabBarMetrics.shared
    @ObservedObject private var reader = ArticleControlsModel.shared

    /// How far to raise the mini player so it sits on the tab bar rather than
    /// wherever this overlay happens to end. Where that edge lands is
    /// SwiftUI's business and not the same on every screen, so it is asked
    /// rather than assumed.
    private func lift(from proxy: GeometryProxy) -> CGFloat {
        guard let pillTop = metrics.pillTop else { return 0 }
        return max(0, proxy.frame(in: .global).maxY - pillTop)
    }

    var body: some View {
        Group {
            TabView(selection: $selectedTab) {
                Tab("Shows", systemImage: "square.stack", value: .shows) {
                    LibraryView(
                        showingVoice: $showingVoice,
                        openEpisode: $showsOpenEpisode)
                }
                Tab("Latest", systemImage: "clock", value: .latest) {
                    LatestView(
                        showingVoice: $showingVoice,
                        openEpisode: $latestOpenEpisode)
                }
                Tab("Settings", systemImage: "gearshape", value: .settings) {
                    SettingsView()
                }
            }
            .id(serverGeneration)
            // Floating over the tab bar rather than pinned under it, and
            // taken away with everything else while she reads: the article's
            // own controls sit above this, and three pieces of furniture
            // leaving one at a time is what the reader looked like before.
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    if !reader.hidden {
                        MiniPlayer(showingNowPlaying: $showingNowPlaying)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            // Raised by however far this overlay's own bottom
                            // edge falls below the tab bar. Where that edge
                            // lands is SwiftUI's business and not the same on
                            // every screen, so it is asked rather than assumed.
                            .padding(.bottom, lift(from: proxy) + ArticleView.gap)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .background(TabBarProbe())
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView(openArticle: openArticleFromPlayer)
        }
        .sheet(isPresented: $showingVoice) {
            VoiceSheet(accountID: auth.user?.id)
                // Consent needs a little more room than the microphone, but
                // still opens as a compact app-owned permission sheet rather
                // than a full-screen document. Once accepted, the familiar
                // medium voice sheet takes over.
                .presentationDetents(
                    auth.user?.aiDataSharingConsented == true
                        ? [.medium, .large]
                        : [.fraction(0.68), .large]
                )
        }
        .task {
            // The Ask Magpie intent may have run before this view existed.
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
        .onReceive(NotificationCenter.default.publisher(for: .hearfulServerChanged)) { _ in
            serverGeneration += 1
        }
        .onChange(of: selectedTab) { _, tab in
            if tab != .settings { lastContentTab = tab }
        }
        // Playback's clock advances twice a second. Keeping its observer in a
        // tiny sibling means those ticks update the player without rebuilding
        // the tab and navigation hierarchy around a scrolling article.
        .background(PlaybackFailurePresenter())
    }

    /// Takes the player away and opens the episode without interrupting it.
    /// Settings has no article navigation of its own, so in that one case the
    /// user returns to whichever content tab they most recently used.
    private func openArticleFromPlayer(_ episode: Episode) {
        showingNowPlaying = false

        let destinationTab = selectedTab == .settings ? lastContentTab : selectedTab
        selectedTab = destinationTab
        switch destinationTab {
        case .shows:
            showsOpenEpisode = episode
        case .latest:
            latestOpenEpisode = episode
        case .settings:
            // lastContentTab is only ever Shows or Latest.
            break
        }
    }
}

/// Owns the one root-level playback concern: a terminal failure that must be
/// spoken and presented over whichever screen is open. Kept outside
/// ContentView's observation graph so ordinary position ticks remain local to
/// the mini/full players that actually draw them.
private struct PlaybackFailurePresenter: View {
    @ObservedObject private var playback = PlaybackCoordinator.shared
    @State private var speaker = Speaker()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: playback.playbackFailure) { _, failure in
                guard let failure else { return }
                // VoiceOver reads the alert itself. Without VoiceOver there may be
                // nobody looking at the screen—the spoken interface still needs
                // to explain why a promised episode became silence.
                guard !UIAccessibility.isVoiceOverRunning else { return }
                Task { await speaker.speak(failure.message) }
            }
            .alert(
                "Playback stopped",
                isPresented: Binding(
                    get: { playback.playbackFailure != nil },
                    set: { if !$0 { playback.dismissPlaybackFailure() } })
            ) {
                Button("Try Again") { playback.retryFailedPlayback() }
                Button("Cancel", role: .cancel) { playback.dismissPlaybackFailure() }
            } message: {
                Text(playback.playbackFailure?.message ?? "The episode could not be played.")
            }
    }
}

/// Asks for something to listen to, from wherever she is.
///
/// Every screen carries one, in the same corner, because the question "play me
/// something" is not about the page she happens to be on. It posts rather than
/// holding a binding: the sheet belongs to the root, and threading a binding
/// down through every navigation stack to reach a toolbar button is a lot of
/// plumbing for one notification.
struct MicToolbarButton: View {
    var body: some View {
        Button {
            Feedback.shared.play(.opened)
            NotificationCenter.default.post(name: .hearfulAskByVoice, object: nil)
        } label: {
            Image(systemName: "mic.fill")
        }
        .accessibilityLabel("Ask for something to listen to")
    }
}

/// Voice is now one way in among several, so it lives in a sheet rather than
/// being the whole screen. Opening it is itself the request to speak, so it
/// listens straight away; tapping it again asks for the next thing.
struct VoiceSheet: View {
    @StateObject private var controller: VoiceController
    @EnvironmentObject private var auth: AuthController
    @Environment(\.dismiss) private var dismiss

    init(accountID: String?) {
        _controller = StateObject(
            wrappedValue: VoiceController.live(telemetryAccountID: accountID))
    }

    var body: some View {
        Group {
            if auth.user?.aiDataSharingConsented == true {
                consentedBody
            } else if auth.user == nil {
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Checking your AI data-sharing choice…")
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await auth.refreshUser() } }
                        .buttonStyle(.bordered)
                }
                .padding(28)
            } else {
                AIDataSharingConsentView(onNotNow: { dismiss() })
            }
        }
    }

    private var consentedBody: some View {
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
                .accessibilityLabel("Ask Magpie")
                .accessibilityValue(caption)
                .accessibilityHint("Double tap to ask for something to listen to")

                // What the app believes it heard, which is the one thing she
                // cannot check by listening — and the thing that explains most
                // answers that look like the model being stupid. It is also
                // what gets sent back with her next sentence, so the exchange
                // on screen is exactly the exchange the model reads.
                if !controller.conversation.isEmpty {
                    TranscriptView(turns: controller.conversation.turns)
                        // Between the microphone and the close button: it is
                        // the record of what happened, which matters more than
                        // the escape hatch and less than the thing she came for.
                        .accessibilitySortPriority(0.5)
                }

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
                        "Opens Magpie's settings, where you can turn on the microphone")
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

/// The exchange so far, oldest at the top.
///
/// Deliberately plain text rather than chat bubbles. Two people read this: she
/// hears it and does not need it, and whoever is helping her works out from it
/// why a request went wrong — for which the useful thing is an unambiguous
/// "this is what you said, this is what it heard", not a shape and a colour.
/// Each turn names its speaker in words, so it survives being read aloud, seen
/// at large type, or seen by someone who cannot tell the two tints apart.
struct TranscriptView: View {
    let turns: [ConversationTurn]

    /// Enough for the last few exchanges without crowding out the microphone,
    /// which she has to be able to hit without aiming. The sheet's large
    /// detent is how a longer history gets read.
    private static let maxHeight: CGFloat = 200

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Indices are stable identity here: the list only ever grows
                // within one exchange, and is cleared whole rather than
                // trimmed, so turn three stays turn three.
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.name(of: turn.speaker))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(turn.text)
                            .font(.body)
                            .foregroundStyle(turn.speaker == .her ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // One utterance is one thing to swipe past, and it reads
                    // as a sentence: "You said, play the Athelstan one."
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(Self.name(of: turn.speaker)) said: \(turn.text)")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        // The newest turn is the one that matters, and it is at the bottom.
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: Self.maxHeight)
        // A container VoiceOver can step into and out of, rather than a run of
        // loose text between the microphone and the close button.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    private static func name(of speaker: ConversationTurn.Speaker) -> String {
        switch speaker {
        case .her: "You"
        case .app: "Magpie"
        }
    }
}

extension VoiceController {
    /// The real wiring. Kept out of the initialiser so tests can inject fakes.
    @MainActor
    static func live(telemetryAccountID: String? = nil) -> VoiceController {
        let canned = ProcessInfo.processInfo.environment["HEARFUL_FAKE_TRANSCRIPT"]
        // Prefer iOS 26's on-device analyser; fall back to the older recogniser
        // where its models are unavailable (notably the simulator).
        let speech = FallbackSpeechRecognizer(
            preferred: AnalyzerSpeechRecognizer(), backup: SpeechRecognizer())
        let api = HearfulAPI()
        return VoiceController(
            api: api,
            speech: canned.map(CannedSpeechRecognizer.init(transcript:)) ?? speech,
            speaker: Speaker(),
            player: PlaybackCoordinator.shared,
            feedback: Feedback.shared,
            telemetry: TelemetryReporter(api: api, accountID: telemetryAccountID))
    }
}

#Preview {
    ContentView()
}
