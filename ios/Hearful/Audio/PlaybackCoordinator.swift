import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// The one place that decides how an episode is played: streamed with
/// AVPlayer, or read aloud by the article player. Everything above it — views,
/// voice control, Siri intents, position reporting — talks to this and never
/// cares which kind of item is active.
///
/// It also owns the lock-screen remote commands, so "play" from AirPods
/// reaches whichever player is actually live.
@MainActor
final class PlaybackCoordinator: ObservableObject, AudioPlaying {
    static let shared = PlaybackCoordinator(audio: .shared, article: .shared)

    enum Mode {
        case audio
        case article
    }

    @Published private(set) var mode: Mode = .audio
    // Mirrors of the active player's state. Published here (rather than
    // computed) so observers get plain Combine streams: the position reporter
    // and every view subscribe to these without knowing about modes.
    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1.0
    @Published private(set) var podcastPlaybackRate: Float = 1.0
    @Published private(set) var articlePlaybackRate: Float = 1.0
    @Published private(set) var playbackFailure: PlaybackFailure?

    let audio: AudioPlayer
    let article: ArticlePlayer
    private var cancellables: Set<AnyCancellable> = []
    private var interruptions = InterruptionPolicy()
    /// Whether she has asked for sound, as opposed to whether sound is coming
    /// out right now.
    ///
    /// The two differ exactly when it matters. AVPlayer pauses itself the
    /// instant an interruption begins, and there is no guarantee our
    /// notification handler runs before `isPlaying` has already gone false —
    /// so deciding whether to resume from `isPlaying` would sometimes conclude
    /// nothing was playing and leave the episode stopped for good. Intent does
    /// not race: nothing but she changes it.
    private var wantsPlayback = false
    /// The follow-up attempts after an interruption ends; see
    /// `resumeAfterInterruption`.
    private var resumeNudge: Task<Void, Never>?
    /// Seconds after the first attempt at which to ask again if it went
    /// nowhere. Internal so the tests can read them.
    static let resumeNudgeDelays: [TimeInterval] = [1, 2, 4]

    init(audio: AudioPlayer, article: ArticlePlayer) {
        self.audio = audio
        self.article = article
        playbackRate = audio.playbackRate
        podcastPlaybackRate = audio.playbackRate
        articlePlaybackRate = article.playbackRate
        mirror(
            episodes: audio.$currentEpisode, playing: audio.$isPlaying,
            times: audio.$currentTime, durations: audio.$duration,
            rates: audio.$playbackRate, when: .audio)
        mirror(
            episodes: article.$currentEpisode, playing: article.$isPlaying,
            times: article.$currentTime, durations: article.$duration,
            rates: article.$playbackRate, when: .article)
        wireRemoteCommands()
        wireAudioSessionEvents()
        wireCompletion()
        wireFailures()
    }

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    /// The audio's length as measured from the loaded asset, or nil while
    /// only the feed's claim is known — and always nil for an article, whose
    /// length is the reader's estimate at her chosen speed.
    var measuredDuration: TimeInterval? {
        mode == .audio && audio.hasMeasuredDuration ? audio.duration : nil
    }

    /// What a list row should say about an episode.
    ///
    /// The one loaded in the player answers from the live clock, so a row and
    /// the player can never disagree about how much is left. Every other row
    /// answers from the position its list was fetched with. Articles keep to
    /// the snapshot: their length is an estimate, and a row that counted
    /// down an estimate would be claiming more than it knows.
    func listeningProgress(for episode: Episode) -> ListeningProgress {
        guard mode == .audio, currentEpisode?.id == episode.id, duration > 0, currentTime > 0
        else { return episode.listeningProgress }
        return ListeningProgress(
            positionSeconds: currentTime, durationSeconds: Int(duration.rounded()),
            completed: nil)
    }

    /// True while the user is dragging the scrubber; forwarded so the ticking
    /// clock does not fight the thumb they are holding.
    var isScrubbing: Bool {
        get { mode == .audio ? audio.isScrubbing : article.isScrubbing }
        set {
            switch mode {
            case .audio: audio.isScrubbing = newValue
            case .article: article.isScrubbing = newValue
            }
        }
    }

    // MARK: - Routing

    static func playsAsArticle(_ episode: Episode) -> Bool {
        episode.audioURL == nil && episode.hasText == true
    }

    func prepare(_ episode: Episode) {
        if Self.playsAsArticle(episode) {
            article.prepare(episode)
        } else {
            audio.prepare(episode)
        }
    }

    func play(_ episode: Episode) throws {
        playbackFailure = nil
        sheTookOver()
        wantsPlayback = true
        if Self.playsAsArticle(episode) {
            audio.pause()
            activate(.article)
            article.play(episode)
        } else {
            article.deactivate()
            activate(.audio)
            do {
                try audio.play(episode)
            } catch {
                wantsPlayback = false
                throw error
            }
        }
    }

    /// Used by on-screen controls, where throwing into `try?` would turn the
    /// only explanation into silence.
    func playReportingFailure(_ episode: Episode) {
        do {
            try play(episode)
        } catch {
            playbackFailure = PlaybackFailure(
                episode: episode,
                message: "Sorry, \(episode.title) could not be played. Check your connection and try again."
            )
            wantsPlayback = false
        }
    }

    func retryFailedPlayback() {
        guard let failure = playbackFailure else { return }
        playReportingFailure(failure.episode)
    }

    func dismissPlaybackFailure() {
        playbackFailure = nil
    }

    /// Loads the last-played item paused at launch, whichever kind it is.
    func restore(_ episode: Episode) {
        if Self.playsAsArticle(episode) {
            activate(.article)
            article.restore(episode)
        } else {
            activate(.audio)
            audio.restore(episode)
        }
    }

    // MARK: - Transport (routed to the active player)

    func pause() {
        sheTookOver()
        wantsPlayback = false
        active.pause()
    }

    func resume() {
        // Nothing loaded, nothing to put back on. Reachable since the player
        // can be emptied: a lock-screen play button, or the voice controller
        // restoring what she interrupted, would otherwise activate the audio
        // session — silencing whatever else is playing — for no sound at all.
        guard currentEpisode != nil else { return }
        sheTookOver()
        wantsPlayback = true
        active.resume()
    }

    /// Her own play, pause or new episode: any interruption still remembered
    /// is over as far as she is concerned, and the follow-up attempts from
    /// the last one have nothing left to do.
    private func sheTookOver() {
        interruptions.reset()
        resumeNudge?.cancel()
        resumeNudge = nil
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    /// Puts the player away: stops sound, unloads both players, clears the
    /// lock screen, and forgets the episode so it does not come back at the
    /// next launch. This is what empties the mini player.
    ///
    /// Both players are cleared, not just the active one, so nothing is left
    /// holding an item that a later mode switch would bring back on screen.
    func clear() {
        sheTookOver()
        wantsPlayback = false
        audio.clear()
        article.clear()
        // Last: the players' own pausing writes to the now-playing info, so
        // emptying it any earlier just refills it with a rate and a clock.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        PlaybackRestore.forget()
    }

    func skip(by seconds: TimeInterval) {
        active.skip(by: seconds)
    }

    func seek(to seconds: TimeInterval) {
        switch mode {
        case .audio: audio.seek(to: seconds)
        case .article: article.seek(to: seconds)
        }
    }

    /// Changes the active kind only. Podcast audio and the system article
    /// voice each remember their own comfortable speed.
    func setPlaybackRate(_ rate: Float) {
        switch mode {
        case .audio: setPodcastPlaybackRate(rate)
        case .article: setArticlePlaybackRate(rate)
        }
    }

    func setPodcastPlaybackRate(_ rate: Float) {
        audio.setPlaybackRate(rate)
    }

    func setArticlePlaybackRate(_ rate: Float) {
        article.setPlaybackRate(rate)
    }

    // MARK: - Wiring

    private var active: any TransportControllable {
        mode == .audio ? audio : article
    }

    private func activate(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        // Snap the mirrors to the newly active player immediately; its own
        // publishers only fire on the next change.
        switch newMode {
        case .audio:
            currentEpisode = audio.currentEpisode
            isPlaying = audio.isPlaying
            currentTime = audio.currentTime
            duration = audio.duration
            playbackRate = audio.playbackRate
        case .article:
            currentEpisode = article.currentEpisode
            isPlaying = article.isPlaying
            currentTime = article.currentTime
            duration = article.duration
            playbackRate = article.playbackRate
        }
    }

    private func mirror(
        episodes: Published<Episode?>.Publisher,
        playing: Published<Bool>.Publisher,
        times: Published<TimeInterval>.Publisher,
        durations: Published<TimeInterval>.Publisher,
        rates: Published<Float>.Publisher,
        when expected: Mode
    ) {
        episodes.sink { [weak self] value in
            guard let self, self.mode == expected else { return }
            self.currentEpisode = value
        }.store(in: &cancellables)
        playing.sink { [weak self] value in
            guard let self, self.mode == expected else { return }
            self.isPlaying = value
        }.store(in: &cancellables)
        times.sink { [weak self] value in
            guard let self, self.mode == expected else { return }
            self.currentTime = value
        }.store(in: &cancellables)
        durations.sink { [weak self] value in
            guard let self, self.mode == expected else { return }
            self.duration = value
        }.store(in: &cancellables)
        rates.sink { [weak self] value in
            guard let self else { return }
            switch expected {
            case .audio: self.podcastPlaybackRate = value
            case .article: self.articlePlaybackRate = value
            }
            guard self.mode == expected else { return }
            self.playbackRate = value
        }.store(in: &cancellables)
    }

    /// An episode running out is the end of it, so the player goes away.
    ///
    /// Leaving it up gave her a bar she could not get rid of: it stayed at the
    /// bottom of every screen, said the episode she had just finished, and did
    /// nothing useful — pressing play on an item sitting on its own last second
    /// only starts the outro again. Clearing here rather than in the players
    /// keeps both kinds of item ending the same way.
    ///
    /// The order matters: the players sound their end-of-item cue and land the
    /// clock on the duration before this runs, so the position reporter still
    /// sees a finished episode when clear() publishes the change.
    private func wireCompletion() {
        audio.finished
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.mode == .audio else { return }
                    self.clear()
                }
            }
            .store(in: &cancellables)
        article.finished
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.mode == .article else { return }
                    self.clear()
                }
            }
            .store(in: &cancellables)
    }

    private func wireFailures() {
        audio.failed
            .sink { [weak self] failure in
                MainActor.assumeIsolated {
                    guard let self, self.mode == .audio else { return }
                    self.wantsPlayback = false
                    self.playbackFailure = failure
                }
            }
            .store(in: &cancellables)
    }

    /// Phone calls, alarms, Siri, and headphones being pulled out.
    ///
    /// Without this an interrupted episode simply never comes back: AVPlayer
    /// pauses itself and waits to be told, and the article player is worse —
    /// the synthesiser stops while nothing updates our state, leaving a player
    /// that says it is playing and makes no sound. Neither is something she
    /// can diagnose or fix by looking at the screen.
    private func wireAudioSessionEvents() {
        let centre = NotificationCenter.default
        centre.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in
                guard let event = AudioSessionEventReader.interruption(from: note.userInfo ?? [:])
                else { return }
                MainActor.assumeIsolated { self?.handle(event) }
            }
            .store(in: &cancellables)
        centre.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] note in
                guard let event = AudioSessionEventReader.routeChange(from: note.userInfo ?? [:])
                else { return }
                MainActor.assumeIsolated { self?.handle(event) }
            }
            .store(in: &cancellables)
    }

    /// Internal rather than private: the tests drive this directly, since a
    /// real interruption cannot be staged in a unit test.
    func handle(_ event: AudioSessionEvent) {
        // Decided from intent, not from isPlaying — see wantsPlayback above.
        // decide() records the answer before pause() clears the flag.
        switch interruptions.decide(event, wantsPlayback: wantsPlayback) {
        case .pause:
            // Not pause(): that is her stopping it, and forgets the
            // interruption this is part of.
            wantsPlayback = false
            resumeNudge?.cancel()
            active.pauseForInterruption()
        case .resume:
            resumeAfterInterruption()
        case .nothing:
            break
        }
    }

    /// Puts playback back on once whatever took the audio has finished — and
    /// asks again over the next few seconds if the first ask went nowhere.
    ///
    /// The system announces a call's end a moment before the phone has let go
    /// of the audio hardware, so the first play() after a call can be refused
    /// outright: the session does not activate, the player stays paused, and
    /// she is left with an episode that silently never came back. Each retry
    /// goes through resume(), which activates the session afresh.
    private func resumeAfterInterruption() {
        guard currentEpisode != nil else { return }
        wantsPlayback = true
        active.resume()
        resumeNudge?.cancel()
        resumeNudge = Task { [weak self] in
            for delay in Self.resumeNudgeDelays {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.wantsPlayback,
                    self.active.isStuckAfterPlayRequest
                else { return }
                self.active.resume()
            }
        }
    }

    /// Lock screen, AirPods stems and "Hey Siri, pause" all arrive here — and
    /// must reach the player that is actually making sound.
    private func wireRemoteCommands() {
        let centre = MPRemoteCommandCenter.shared()
        // `isEnabled` declares that the app supports a command, not that the
        // command is the next valid state transition. Keep both directions
        // supported while this app owns Now Playing so iOS can carry the
        // resumable session into the background; the handlers below reject a
        // duplicate event that does not fit the current state.
        centre.playCommand.isEnabled = true
        centre.pauseCommand.isEnabled = true
        centre.togglePlayPauseCommand.isEnabled = true
        centre.playCommand.addTarget { [weak self] _ in
            self?.handleRemotePlay() ?? .noActionableNowPlayingItem
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            self?.handleRemotePause() ?? .noActionableNowPlayingItem
        }
        // Some accessories and system surfaces send a state-independent
        // toggle rather than separate play/pause events. Leaving the command
        // enabled without a handler makes those taps look accepted while the
        // article does nothing.
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleRemoteToggle() ?? .noActionableNowPlayingItem
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

    /// Internal so tests can deliver the same events as the system controls
    /// without relying on a lock screen. A stale duplicate is a failure, not a
    /// successful second state transition.
    func handleRemotePlay() -> MPRemoteCommandHandlerStatus {
        guard currentEpisode != nil else { return .noActionableNowPlayingItem }
        guard !isPlaying else { return .commandFailed }
        resume()
        return .success
    }

    func handleRemotePause() -> MPRemoteCommandHandlerStatus {
        guard currentEpisode != nil else { return .noActionableNowPlayingItem }
        guard isPlaying else { return .commandFailed }
        pause()
        return .success
    }

    func handleRemoteToggle() -> MPRemoteCommandHandlerStatus {
        guard currentEpisode != nil else { return .noActionableNowPlayingItem }
        toggle()
        return .success
    }
}

/// The transport surface both players share, so the coordinator can route
/// commands without caring which one is live.
@MainActor
protocol TransportControllable {
    func pause()
    /// The system has taken the audio — a call, an alarm. Not her decision,
    /// unlike pause(), and a player may prefer to stop outright and start the
    /// current passage again when the audio is given back.
    func pauseForInterruption()
    func resume()
    /// Play was asked for and nothing has begun: not playing, not buffering,
    /// the request simply refused. False where the player cannot tell.
    var isStuckAfterPlayRequest: Bool { get }
    func skip(by seconds: TimeInterval)
}

extension AudioPlayer: TransportControllable {}
extension ArticlePlayer: TransportControllable {}
