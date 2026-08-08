import AVFoundation
import MediaPlayer

/// Streams episode audio, publishes it to the lock screen, and exposes enough
/// state for a UI to draw a scrubber.
@MainActor
final class AudioPlayer: NSObject, AudioPlaying, ObservableObject {
    /// One player for the whole app. Siri intents run without any UI, so
    /// playback cannot belong to a view that may never have been created.
    static let shared = AudioPlayer()

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// True while the user is dragging the scrubber, so the ticking clock does
    /// not fight the thumb they are holding.
    @Published var isScrubbing = false

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var playbackStateObservation: NSKeyValueObservation?

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    override init() {
        super.init()
        wireRemoteCommands()
        observeTime()
        observePlaybackState()
    }

    // MARK: - Playback

    /// Loads the item without starting it, so buffering overlaps the spoken
    /// confirmation instead of following it.
    func prepare(_ episode: Episode) {
        guard let url = episode.audioURL, episode.id != currentEpisode?.id else { return }
        try? AudioSession.configureForPlayback()
        replaceItem(url: url, episode: episode)
    }

    func play(_ episode: Episode) throws {
        guard let url = episode.audioURL else {
            throw PlaybackError.noAudio
        }
        try AudioSession.configureForPlayback()
        // Usually already loaded by prepare(); only swap if it is a new episode.
        if currentEpisode?.id != episode.id || player.currentItem == nil {
            replaceItem(url: url, episode: episode)
        }
        player.play()
        publishNowPlaying(episode)
    }

    func pause() {
        player.pause()
        updateNowPlayingPosition()
    }

    func resume() {
        try? AudioSession.configureForPlayback()
        player.play()
        updateNowPlayingPosition()
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: TimeInterval) {
        let clamped = min(max(seconds, 0), duration > 0 ? duration : seconds)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        updateNowPlayingPosition()
    }

    private func replaceItem(url: URL, episode: Episode) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        currentEpisode = episode
        currentTime = 0
        // The feed's stated duration is a good enough starting value; the real
        // one arrives once the asset has loaded.
        duration = episode.durationSeconds.map(Double.init) ?? 0
        // Resume where she left off — but not for an episode she finished,
        // not within the first moments (starting over costs nothing), and not
        // into the final seconds (an outro is worse than a fresh start).
        let resumeAt = episode.completed == true ? 0 : (episode.positionSeconds ?? 0)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in
                guard let self else { return }
                let seconds = item.duration.seconds
                if seconds.isFinite, seconds > 0 { self.duration = seconds }
                if resumeAt > 5, resumeAt < self.duration - 10 {
                    self.seek(to: resumeAt)
                }
            }
        }
    }

    // MARK: - Observation

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds
            }
        }
    }

    private func observePlaybackState() {
        // timeControlStatus covers stalls and buffering, which a plain rate
        // check reports as "playing" while no sound is coming out.
        // The token must be retained: a discarded NSKeyValueObservation
        // invalidates itself immediately and isPlaying never updates.
        playbackStateObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
    }

    // MARK: - Lock screen

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
        centre.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func publishNowPlaying(_ episode: Episode) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: episode.title]
        if let duration = episode.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = Double(duration)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPosition() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    enum PlaybackError: Error {
        case noAudio
    }
}
