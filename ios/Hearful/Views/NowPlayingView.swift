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
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)

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
        Menu {
            ForEach(AudioPlayer.playbackRates, id: \.self) { rate in
                Button {
                    player.setPlaybackRate(rate)
                } label: {
                    if rate == player.playbackRate {
                        Label(speedLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(rate))
                    }
                }
            }
        } label: {
            Text(speedLabel(player.playbackRate))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(spokenSpeed(player.playbackRate))
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

/// The bar above the tab bar. Tapping it opens the full player.
struct MiniPlayer: View {
    @ObservedObject private var player = PlaybackCoordinator.shared
    @Binding var showingNowPlaying: Bool

    var body: some View {
        if let episode = player.currentEpisode {
            HStack(spacing: 12) {
                Artwork(url: episode.imageURL, size: 40)
                Text(episode.title).font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                // A hairline progress bar: enough to see where you are without
                // taking any vertical space.
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * player.progress, height: 2)
                }
                .frame(height: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture { showingNowPlaying = true }
            .accessibilityElement(children: .contain)
        }
    }
}
