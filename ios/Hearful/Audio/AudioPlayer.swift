import AVFoundation
import Combine
import OSLog

private let playbackLog = Logger(
    subsystem: "com.henrydashwood.hearful", category: "playback")

nonisolated struct PlaybackFailure: Identifiable, Equatable {
    var id: Int { episode.id }
    let episode: Episode
    let message: String
}

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
    /// True once the loaded asset has said how long it is. Until then
    /// `duration` is the feed's claim, which is not worth repeating to anyone.
    private(set) var hasMeasuredDuration = false
    /// True while the user is dragging the scrubber, so the ticking clock does
    /// not fight the thumb they are holding.
    @Published var isScrubbing = false
    @Published private(set) var playbackRate: Float = 1.0

    static let playbackRates = PlaybackSpeedPreference.rates

    private let player: AVPlayer
    private let activateAudioSession: @MainActor () throws -> Void
    private var needsInterruptionRecovery = false
    private let defaults: UserDefaults
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var playbackStateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failedToEndObserver: NSObjectProtocol?
    private var stallTask: Task<Void, Never>?
    private var playbackRequested = false
    private var failedEpisodeID: Int?
    /// True while a seek is still landing, during which AVPlayer's clock still
    /// reads the old position and must not be published. See `seek`.
    private var isSeeking = false
    /// Identifies the newest seek, so an older one completing cannot clear
    /// `isSeeking` out from under it.
    private var seekGeneration = 0
    /// Sounded when an item reaches its end. Injectable so the tests can watch
    /// for it without a speaker.
    var feedback: FeedbackPlaying = Feedback.shared
    /// Announces that the current item has run out, for the coordinator to act
    /// on. The player itself does not decide what happens next.
    let finished = PassthroughSubject<Void, Never>()
    /// A terminal failure after play() returned successfully. The coordinator
    /// turns this into speech, an alert and a retry action.
    let failed = PassthroughSubject<PlaybackFailure, Never>()

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    override convenience init() {
        self.init(defaults: .standard)
    }

    init(
        defaults: UserDefaults,
        player: AVPlayer = AVPlayer(),
        activateAudioSession: @escaping @MainActor () throws -> Void = AudioSession.configureForPlayback
    ) {
        self.defaults = defaults
        self.player = player
        self.activateAudioSession = activateAudioSession
        super.init()
        playbackRate = PlaybackSpeedPreference.load(.podcast, defaults: defaults)
        // defaultRate makes every play()/resume() come back at her speed
        // without each call site having to remember it.
        player.defaultRate = playbackRate
        observeTime()
        observePlaybackState()
    }

    /// Sets how fast episodes play, remembered across launches and episodes.
    func setPlaybackRate(_ rate: Float) {
        let clamped = PlaybackSpeedPreference.clamped(rate)
        playbackRate = clamped
        PlaybackSpeedPreference.save(clamped, for: .podcast, defaults: defaults)
        player.defaultRate = clamped
        // `isPlaying` is false while AVPlayer is buffering even though a
        // play request is still active. Updating only in the .playing state
        // made a speed tap during that window update the chip but leave the
        // pending playback at its old rate.
        if playbackRequested { player.rate = clamped }
    }

    var isReadyToPlay: Bool { player.currentItem?.status == .readyToPlay }

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
        try activateAudioSession()
        playbackRequested = true
        // Usually already loaded by prepare(); only swap if it is a new episode.
        if currentEpisode?.id != episode.id || player.currentItem == nil
            || player.currentItem?.status == .failed || failedEpisodeID == episode.id
            || needsInterruptionRecovery
        {
            // Trying the same episode again after a failure carries on from
            // the clock, not from the position the list was fetched with —
            // which by now may be an hour behind where she actually was.
            let retrying = currentEpisode?.id == episode.id && currentTime > 0
            replaceItem(url: url, episode: episode, resumeAt: retrying ? currentTime : nil)
        }
        player.play()
    }

    func pause() {
        playbackRequested = false
        stallTask?.cancel()
        player.pause()
    }

    /// AVPlayer stops itself when the system takes the audio. Its item can
    /// remain unusable without reporting failure, so rebuild it at the live
    /// position on the next successful activation instead of replaying it.
    func pauseForInterruption() {
        needsInterruptionRecovery = currentEpisode != nil
        pause()
    }

    func resume() {
        guard currentEpisode != nil else { return }
        playbackRequested = true
        do {
            try activateAudioSession()
        } catch {
            playbackLog.notice("Audio session is not ready to resume: \(error.localizedDescription, privacy: .private)")
            return
        }
        if let episode = currentEpisode, let url = episode.audioURL,
            needsInterruptionRecovery || player.currentItem?.status == .failed || failedEpisodeID == episode.id
        {
            replaceItem(url: url, episode: episode, resumeAt: currentTime > 0 ? currentTime : nil)
        }
        player.play()
    }

    /// Play was asked for and the player has not so much as begun — not
    /// playing, not buffering, the request simply refused. It happens after a
    /// phone call: the system says the call has ended a moment before the
    /// phone has let go of the audio hardware, and the session will not
    /// activate. A second ask a moment later is accepted.
    var isStuckAfterPlayRequest: Bool {
        playbackRequested && player.timeControlStatus == .paused
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    /// Stops and unloads, leaving nothing loaded at all.
    ///
    /// The episode is published as nil before the clock is wound back: the
    /// position reporter flushes on that change and works out from the
    /// duration whether she finished it, so zeroing first would file a
    /// finished episode as unplayed.
    func clear() {
        playbackRequested = false
        stallTask?.cancel()
        player.pause()
        currentEpisode = nil
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
        currentTime = 0
        duration = 0
        hasMeasuredDuration = false
        isPlaying = false
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: TimeInterval) {
        let clamped = min(max(seconds, 0), duration > 0 ? duration : seconds)

        // A zero-tolerance seek is precise, which means it takes real time to
        // land. Until it does, the periodic observer below keeps reporting the
        // position we are leaving — so without this flag every skip published
        // three positions: the new one, the old one again, then the new one.
        // The middle of those is a stale position being written to the server,
        // and if the app dies in that window she resumes in the wrong place.
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only the newest seek may clear the flag: tapping skip three
                // times in a row must not have the first landing re-open the
                // window while the third is still in flight.
                guard self.seekGeneration == generation else { return }
                self.isSeeking = false
            }
        }
        currentTime = clamped
    }

    /// `resumeAt` overrides the episode's saved position, for a retry of the
    /// item she was already part-way through.
    private func replaceItem(url: URL, episode: Episode, resumeAt: TimeInterval? = nil) {
        stallTask?.cancel()
        failedEpisodeID = nil
        needsInterruptionRecovery = false
        // A recovery keeps the live position, including the first/last few
        // seconds. Do not publish the replacement item's temporary zero or
        // accept a seek callback from the retired item while it loads.
        seekGeneration += 1
        isSeeking = resumeAt != nil
        let item = AVPlayerItem(url: url)
        // timeDomain keeps speech natural at raised speeds; the default
        // algorithm turns 1.5x podcasts into chipmunks-adjacent audio.
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
        currentEpisode = episode
        PlaybackRestore.remember(episodeID: episode.id)
        currentTime = resumeAt ?? 0
        // The feed's stated duration is a good enough starting value; the real
        // one arrives once the asset has loaded.
        duration = episode.durationSeconds.map(Double.init) ?? 0
        hasMeasuredDuration = false
        // Resume where she left off — but not for an episode she finished,
        // not within the first moments (starting over costs nothing), and not
        // into the final seconds (an outro is worse than a fresh start).
        let explicitResumeAt = resumeAt
        let resumeAt = resumeAt ?? (episode.completed == true ? 0 : (episode.positionSeconds ?? 0))
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed {
                    if self.playbackRequested {
                        self.reportFailure(
                            for: episode,
                            underlying: item.error?.localizedDescription ?? "player item failed")
                    }
                    return
                }
                guard item.status == .readyToPlay else { return }
                let seconds = item.duration.seconds
                if seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                    self.hasMeasuredDuration = true
                }
                if let explicitResumeAt {
                    self.seek(to: explicitResumeAt)
                } else if resumeAt > 5, resumeAt < self.duration - 10 {
                    self.seek(to: resumeAt)
                }
            }
        }
    }

    // MARK: - Observation

    /// Watches for the episode running out, which is otherwise indistinguishable
    /// from everything having gone wrong. Scoped to one item and replaced with
    /// it, so an old episode's ending cannot chime over a new one.
    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Land exactly on the end so the position reporter, which is
                // watching this clock, records the episode as finished.
                self.currentTime = self.duration
                self.feedback.play(.finished)
                self.finished.send()
            }
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            // Pull the only Sendable value we need out before entering the
            // actor-isolated closure; Notification itself is not Sendable.
            let underlying =
                (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "failed before reaching the end"
            MainActor.assumeIsolated {
                guard let self, self.playbackRequested, let episode = self.currentEpisode else {
                    return
                }
                self.reportFailure(for: episode, underlying: underlying)
            }
        }
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                // isScrubbing: her thumb is on the slider and owns the number.
                // isSeeking: the clock has not caught up with where we jumped.
                guard let self, !self.isScrubbing, !self.isSeeking else { return }
                // With no item loaded — after clear() — the clock is invalid
                // and reads as NaN, which would spread to the progress bar and
                // to the position written to the server.
                guard time.seconds.isFinite else { return }
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
                switch player.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate where self.playbackRequested:
                    self.scheduleStallFailure(for: self.currentEpisode)
                default:
                    self.stallTask?.cancel()
                }
            }
        }
    }

    private func scheduleStallFailure(for episode: Episode?) {
        guard let episode else { return }
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.playbackRequested,
                self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                self.currentEpisode?.id == episode.id
            else { return }
            self.reportFailure(for: episode, underlying: "playback remained stalled for 20 seconds")
        }
    }

    /// Internal so the coordinator tests can exercise the asynchronous-failure
    /// path without depending on a real network stream.
    func reportFailure(for episode: Episode, underlying: String) {
        guard currentEpisode?.id == episode.id, failedEpisodeID != episode.id else { return }
        failedEpisodeID = episode.id
        playbackRequested = false
        stallTask?.cancel()
        player.pause()
        isPlaying = false
        playbackLog.error(
            "Playback failed for episode \(episode.id, privacy: .public): \(underlying, privacy: .private)"
        )
        failed.send(
            PlaybackFailure(
                episode: episode,
                message: "Sorry, \(episode.title) could not be played. Check your connection and try again."
            ))
    }

    enum PlaybackError: Error {
        case noAudio
    }
}
