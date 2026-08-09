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

    let audio: AudioPlayer
    let article: ArticlePlayer
    private var cancellables: Set<AnyCancellable> = []

    init(audio: AudioPlayer, article: ArticlePlayer) {
        self.audio = audio
        self.article = article
        playbackRate = audio.playbackRate
        mirror(
            episodes: audio.$currentEpisode, playing: audio.$isPlaying,
            times: audio.$currentTime, durations: audio.$duration,
            rates: audio.$playbackRate, when: .audio)
        mirror(
            episodes: article.$currentEpisode, playing: article.$isPlaying,
            times: article.$currentTime, durations: article.$duration,
            rates: article.$playbackRate, when: .article)
        wireRemoteCommands()
    }

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
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
        if Self.playsAsArticle(episode) {
            audio.pause()
            activate(.article)
            article.play(episode)
        } else {
            article.deactivate()
            activate(.audio)
            try audio.play(episode)
        }
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
        active.pause()
    }

    func resume() {
        active.resume()
    }

    func toggle() {
        isPlaying ? pause() : resume()
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

    /// Applied to both players: her preferred speed follows her between
    /// podcasts and articles, and AudioPlayer persists it.
    func setPlaybackRate(_ rate: Float) {
        audio.setPlaybackRate(rate)
        article.setPlaybackRate(rate)
        playbackRate = min(max(rate, 0.5), 3.0)
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
        case .article:
            currentEpisode = article.currentEpisode
            isPlaying = article.isPlaying
            currentTime = article.currentTime
            duration = article.duration
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
            guard let self, self.mode == expected else { return }
            self.playbackRate = value
        }.store(in: &cancellables)
    }

    /// Lock screen, AirPods stems and "Hey Siri, pause" all arrive here — and
    /// must reach the player that is actually making sound.
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
}

/// The transport surface both players share, so the coordinator can route
/// commands without caring which one is live.
@MainActor
protocol TransportControllable {
    func pause()
    func resume()
    func skip(by seconds: TimeInterval)
}

extension AudioPlayer: TransportControllable {}
extension ArticlePlayer: TransportControllable {}
