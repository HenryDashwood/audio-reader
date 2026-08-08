import SwiftUI

/// Full-screen player: artwork, scrubber, and the transport controls people
/// expect from any podcast app.
struct NowPlayingView: View {
    @ObservedObject private var player = AudioPlayer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition: TimeInterval = 0

    var body: some View {
        VStack(spacing: 28) {
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)

            Artwork(url: nil, size: 260)
                .shadow(radius: 12, y: 6)
                .padding(.top, 12)

            Text(player.currentEpisode?.title ?? "Nothing playing")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 28)

            scrubber
            transport

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
}

/// The bar above the tab bar. Tapping it opens the full player.
struct MiniPlayer: View {
    @ObservedObject private var player = AudioPlayer.shared
    @Binding var showingNowPlaying: Bool

    var body: some View {
        if let episode = player.currentEpisode {
            HStack(spacing: 12) {
                Artwork(url: nil, size: 40)
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
