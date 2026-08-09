import AVFoundation
import MediaPlayer
import UIKit

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
    @Published private(set) var playbackRate: Float = 1.0

    static let playbackRates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private static let rateKey = "HearfulPlaybackRate"

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var playbackStateObservation: NSKeyValueObservation?

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    override init() {
        super.init()
        let stored = UserDefaults.standard.float(forKey: Self.rateKey)
        playbackRate = stored > 0 ? stored : 1.0
        // defaultRate makes every play()/resume() come back at her speed
        // without each call site having to remember it.
        player.defaultRate = playbackRate
        wireRemoteCommands()
        observeTime()
        observePlaybackState()
    }

    /// Sets how fast episodes play, remembered across launches and episodes.
    func setPlaybackRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 3.0)
        playbackRate = clamped
        UserDefaults.standard.set(clamped, forKey: Self.rateKey)
        player.defaultRate = clamped
        if isPlaying { player.rate = clamped }
        updateNowPlayingPosition()
    }

    // MARK: - Playback

    /// Loads the item without starting it, so buffering overlaps the spoken
    /// confirmation instead of following it.
    func prepare(_ episode: Episode) {
        guard let url = episode.audioURL, episode.id != currentEpisode?.id else { return }
        try? AudioSession.configureForPlayback()
        replaceItem(url: url, episode: episode)
    }

    /// Loads an episode paused at launch so the mini player is waiting for
    /// her. Unlike prepare(), the audio session is left alone: activating it
    /// here would silence whatever another app is playing, just for opening
    /// the app. resume()/play() activate it when she actually wants sound.
    func restore(_ episode: Episode) {
        guard currentEpisode == nil, let url = episode.audioURL else { return }
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
        updateNowPlayingPosition()
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
        // timeDomain keeps speech natural at raised speeds; the default
        // algorithm turns 1.5x podcasts into chipmunks-adjacent audio.
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        currentEpisode = episode
        PlaybackRestore.remember(episodeID: episode.id)
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
                // The asset's real duration replaces the feed's estimate.
                self.updateNowPlayingPosition()
            }
        }
        // Published on load, not on play: an episode restored at launch and
        // started from the mini player or the lock screen must carry its
        // title and artwork too, not just working buttons.
        publishNowPlaying(episode)
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
                guard let self else { return }
                self.isPlaying = player.timeControlStatus == .playing
                // Keep the lock screen's clock in step: it ticks on its own
                // from the published rate, not from our elapsed-time updates.
                self.updateNowPlayingPosition()
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
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        publishArtwork(for: episode)
    }

    /// Fetched after the text is already up: the lock screen should never
    /// wait on an image, and a failed fetch just leaves the placeholder.
    private func publishArtwork(for episode: Episode) {
        guard let url = episode.imageURL else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                let image = UIImage(data: data)
            else { return }
            guard self?.currentEpisode?.id == episode.id else { return }  // she moved on
            // @Sendable, not main-actor: MediaPlayer renders the artwork on
            // its own queue, and a main-actor closure traps when it does.
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func updateNowPlayingPosition() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    enum PlaybackError: Error {
        case noAudio
    }
}
