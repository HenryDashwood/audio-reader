import AVFoundation
import MediaPlayer

/// Streams episode audio and publishes it to the lock screen.
@MainActor
final class AudioPlayer: NSObject, AudioPlaying {
    /// One player for the whole app. Siri intents run without any UI, so
    /// playback cannot belong to a view that may never have been created.
    static let shared = AudioPlayer()

    private let player = AVPlayer()
    private var currentEpisode: Episode?

    var isPlaying: Bool { player.timeControlStatus == .playing }

    override init() {
        super.init()
        wireRemoteCommands()
    }

    /// Loads the item without starting it, so buffering overlaps the spoken
    /// confirmation instead of following it.
    func prepare(_ episode: Episode) {
        guard let url = episode.audioURL, episode.id != currentEpisode?.id else { return }
        try? AudioSession.configureForPlayback()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        currentEpisode = episode
    }

    func play(_ episode: Episode) throws {
        guard let url = episode.audioURL else {
            throw PlaybackError.noAudio
        }
        try AudioSession.configureForPlayback()
        // Usually already loaded by prepare(); only swap if it is a new episode.
        if currentEpisode?.id != episode.id || player.currentItem == nil {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        player.play()
        currentEpisode = episode
        publishNowPlaying(episode)
    }

    func pause() {
        player.pause()
    }

    func resume() {
        try? AudioSession.configureForPlayback()
        player.play()
    }

    func skip(by seconds: TimeInterval) {
        let target = player.currentTime() + CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: CMTimeMaximum(.zero, target))
    }

    /// Lock screen, AirPods stems and "Hey Siri, pause" all arrive here — none
    /// of which need the app open or the screen looked at.
    private func wireRemoteCommands() {
        let centre = MPRemoteCommandCenter.shared()
        centre.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        centre.skipForwardCommand.preferredIntervals = [30]
        centre.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 30)
            return .success
        }
        centre.skipBackwardCommand.preferredIntervals = [15]
        centre.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -15)
            return .success
        }
    }

    private func publishNowPlaying(_ episode: Episode) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: episode.title]
        if let duration = episode.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = Double(duration)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    enum PlaybackError: Error {
        case noAudio
    }
}
