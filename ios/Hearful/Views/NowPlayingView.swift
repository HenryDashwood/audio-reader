import SwiftUI

/// Full-screen player: artwork, scrubber, and the transport controls people
/// expect from any podcast app.
struct NowPlayingView: View {
    @ObservedObject private var player = PlaybackCoordinator.shared
    @ObservedObject private var sleepTimer = SleepTimer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition: TimeInterval = 0

    var body: some View {
        VStack(spacing: 28) {
            // The capsule reads as "drag me down" to anyone who can see it and
            // means nothing at all to anyone who cannot, so it is decorative
            // and there is a real button beside it. Swiping a sheet away has
            // no simple VoiceOver equivalent — only the two-finger scrub, which
            // almost nobody knows — and a screen you can enter but not leave is
            // worse than one you cannot enter.
            ZStack {
                Capsule()
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 40, height: 5)
                    .accessibilityHidden(true)
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close player")
                    .accessibilityHint("Goes back to the list you came from")
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 8)

            Artwork(url: player.currentEpisode?.imageURL, size: 260)
                .shadow(radius: 12, y: 6)
                .padding(.top, 12)

            Text(player.currentEpisode?.title ?? "Nothing playing")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 28)

            scrubber
            transport
            HStack(spacing: 16) {
                speedControl
                sleepControl
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 32)
        .presentationDragIndicator(.hidden)
        // The episode can go away underneath this screen — it ended, or she
        // closed the player from elsewhere. Staying open on "Nothing playing"
        // with dead controls tells her nothing; going back to the list she
        // came from is the same thing that happens when she closes it herself.
        .onChange(of: player.currentEpisode == nil) { _, empty in
            if empty { dismiss() }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { player.isScrubbing ? scrubPosition : player.currentTime },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    player.isScrubbing = editing
                    // Seek once, on release — seeking continuously while
                    // dragging makes a streamed episode stutter badly.
                    if !editing { player.seek(to: scrubPosition) }
                }
            )
            .disabled(player.currentEpisode == nil)
            .accessibilityLabel("Playback position")
            .accessibilityValue(formatDuration(player.currentTime))

            HStack {
                Text(formatDuration(player.currentTime))
                Spacer()
                Text("−" + formatDuration(max(player.duration - player.currentTime, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.title)
            }
            .accessibilityLabel("Back 15 seconds")

            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.skip(by: 30) } label: {
                Image(systemName: "goforward.30").font(.title)
            }
            .accessibilityLabel("Forward 30 seconds")
        }
        .disabled(player.currentEpisode == nil)
    }

    private var speedControl: some View {
        Picker(
            selection: Binding(
                get: { player.playbackRate },
                set: { player.setPlaybackRate($0) }
            ),
            content: {
                ForEach(AudioPlayer.playbackRates, id: \.self) { rate in
                    Text(speedLabel(rate)).tag(rate)
                }
            }
        ) {
            Text(speedLabel(player.playbackRate))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
                .contentShape(Capsule())
        }
        // Picker gives the system menu one stable selection binding instead
        // of rebuilding its Button rows while a tap is being completed.
        .pickerStyle(.menu)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(spokenSpeed(player.playbackRate))
        // The new rate is audible only once playback advances far enough to
        // make the difference obvious. A light selection tick confirms the
        // option landed immediately, including while the episode is paused.
        .sensoryFeedback(.selection, trigger: player.playbackRate)
    }

    private var sleepControl: some View {
        Menu {
            ForEach(SleepTimer.options, id: \.self) { minutes in
                Button("\(minutes) minutes") { sleepTimer.start(minutes: minutes) }
            }
            if sleepTimer.isRunning {
                Divider()
                Button("Turn off sleep timer", role: .destructive) { sleepTimer.cancel() }
            }
        } label: {
            // Redrawn every half minute so a running timer counts down rather
            // than showing whatever it said when the sheet was opened.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Group {
                    // The countdown is worth the width only while it is
                    // counting; otherwise the icon says everything.
                    if sleepTimer.isRunning {
                        Label(sleepLabel, systemImage: "moon.zzz")
                    } else {
                        Image(systemName: "moon.zzz")
                    }
                }
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(sleepBackground, in: Capsule())
            }
        }
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(sleepTimer.isRunning ? "stopping in \(sleepLabel)" : "off")
    }

    private var sleepBackground: AnyShapeStyle {
        sleepTimer.isRunning ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary)
    }

    /// Minutes left, rounded up: "1 min" through the last sixty seconds,
    /// rather than "0 min" for most of it.
    private var sleepLabel: String {
        guard let remaining = sleepTimer.remaining else { return "Sleep" }
        return "\(max(1, Int(ceil(remaining / 60)))) min"
    }

    private func speedLabel(_ rate: Float) -> String {
        // "1×", "1.5×" — trailing zeros stripped so the chip stays narrow.
        let number = rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rate)) : String(format: "%g", rate)
        return "\(number)×"
    }

    private func spokenSpeed(_ rate: Float) -> String {
        rate == 1 ? "Normal speed" : "\(String(format: "%g", rate)) times speed"
    }
}

/// What is playing, floating just above the tab bar. Tapping it opens the
/// full player.
///
/// A capsule rather than a bar across the bottom of the screen: it is one of
/// three pieces of furniture that come and go down there — the tab bar, the
/// reader's controls, this — and a full-width opaque strip among two floating
/// capsules read as a different app's idea. Cut to the tab bar's own width so
/// the three line up.
struct MiniPlayer: View {
    @ObservedObject private var player = PlaybackCoordinator.shared
    @ObservedObject private var metrics = TabBarMetrics.shared
    @Binding var showingNowPlaying: Bool

    static let height: CGFloat = 52

    var body: some View {
        if let episode = player.currentEpisode {
            HStack(spacing: 0) {
                // A button rather than a tap gesture on the whole capsule. The
                // gesture worked by sight but was invisible to VoiceOver: the
                // container was never exposed as a control, so there was no
                // way to reach the player screen — and with it the scrubber,
                // the speed control and the sleep timer — without seeing it.
                Button {
                    showingNowPlaying = true
                } label: {
                    HStack(spacing: 10) {
                        Artwork(url: episode.imageURL, size: 32)
                        Text(episode.title).font(.subheadline).lineLimit(1)
                        Spacer(minLength: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(episode.title)")
                .accessibilityHint("Opens the player, with the scrubber and sleep timer")

                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body)
                        .frame(width: 38, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                // The way out. Everything else here assumes she still wants
                // the episode; nothing until now let her say she does not, so
                // the bar sat across the bottom of every screen with no way to
                // be rid of it. Deliberately a button and not a swipe: a
                // gesture here would be reachable by sight only, and this is
                // the one control whose absence left her stuck.
                Button { player.clear() } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop and close player")
                .accessibilityHint("Stops the episode and takes this away")
            }
            .padding(.leading, 10)
            .padding(.trailing, 2)
            .frame(width: metrics.pillWidth ?? TabBarMetrics.fallbackWidth, height: Self.height)
            .glassEffect(in: .capsule)
            .overlay(alignment: .bottom) {
                // A hairline of progress along the foot of the capsule: enough
                // to see where you are without taking any height.
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * player.progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
                // Purely visual, and duplicated properly by the scrubber on the
                // player screen. As a VoiceOver element it would just be an
                // unlabelled shape between the buttons.
                .accessibilityHidden(true)
            }
        }
    }
}

/// Measures the tab bar for the capsules that float above it.
///
/// Lives at the root rather than in the reader, because the mini player wants
/// the same measurements on every tab and there is no article open there.
struct TabBarProbe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) {}

    final class Probe: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            measure()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            measure()
            // The tab bar is often not laid out at its final size on the pass
            // that brings this view up, and nothing lays this view out again
            // afterwards — so ask once more when the dust has settled.
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        private func measure() {
            TabBarMetrics.shared.measure(from: Self.tabBar(near: view))
        }

        /// The tab bar, found by looking through the window rather than up the
        /// parent chain.
        ///
        /// `tabBarController` only answers for a controller inside the tab bar
        /// controller's own hierarchy, and this one is not: it hangs off the
        /// background of the tab view, which in UIKit terms puts it alongside
        /// the tab bar controller rather than within it. So it asked, got
        /// nothing, measured nothing, and the mini player — having nothing to
        /// sit on — sat on the tab bar instead.
        private static func tabBar(near view: UIView) -> UITabBar? {
            guard let root = view.window?.rootViewController else { return nil }
            return search(root)
        }

        private static func search(_ controller: UIViewController) -> UITabBar? {
            if let tabs = controller as? UITabBarController { return tabs.tabBar }
            for child in controller.children {
                if let found = search(child) { return found }
            }
            if let presented = controller.presentedViewController {
                return search(presented)
            }
            return nil
        }
    }
}
