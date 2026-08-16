import Combine
import UIKit

/// Watches playback and tells the backend where she is in each episode.
///
/// A separate observer rather than code inside the players, so they keep zero
/// network dependencies. It observes the coordinator's mirrored state, so an
/// article being read aloud reports its (estimated-seconds) position exactly
/// like a streamed episode. Reports are fire-and-forget: losing one costs at
/// most thirty seconds of position, which matters less than never blocking
/// playback on the network.
@MainActor
final class PositionReporter {
    static let heartbeatInterval: TimeInterval = 30
    /// A between-tick change bigger than this is a seek, not the clock ticking.
    static let seekJumpThreshold: TimeInterval = 2.5

    private let api: HearfulAPIProtocol
    private let player: PlaybackCoordinator
    private var cancellables: Set<AnyCancellable> = []

    private(set) var trackedEpisode: Episode?
    /// Episodes she has filed by hand: marked played, or put aside.
    ///
    /// Their state is hers to decide, not the clock's. Without this, marking
    /// the episode she is listening to as played is undone within seconds:
    /// pausing it flushes a position, the flush reports `completed` worked out
    /// from how far through she is, and the answer is false. She would hear
    /// the confirmation, and the episode would be back in her list.
    private var filedByHand: Set<Int> = []
    private var lastTime: TimeInterval = 0
    /// Nothing is reported for an episode that was only loaded, never played:
    /// prepare() must not overwrite a saved position with zero.
    private var hasPlayed = false
    private var lastReportAt: Date = .distantPast

    init(
        api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
        player: PlaybackCoordinator = .shared
    ) {
        self.api = api
        self.player = player

        player.$currentEpisode
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] episode in
                MainActor.assumeIsolated { self?.episodeChanged(to: episode) }
            }
            .store(in: &cancellables)
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                MainActor.assumeIsolated { self?.playingChanged(playing) }
            }
            .store(in: &cancellables)
        player.$currentTime
            .sink { [weak self] time in
                MainActor.assumeIsolated { self?.timeTicked(to: time) }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .hearfulEpisodeFiled)
            .sink { [weak self] note in
                guard let change = note.object as? EpisodeFiling.Change else { return }
                MainActor.assumeIsolated { self?.episodeFiled(change) }
            }
            .store(in: &cancellables)
        // Backgrounding is the last reliable moment to write before iOS may
        // kill the process.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
            .store(in: &cancellables)
    }

    // Internal rather than private: tests drive these directly, since
    // AudioPlayer's published state cannot be forced without real audio.

    func episodeChanged(to episode: Episode?) {
        if let outgoing = trackedEpisode, outgoing.id != episode?.id, hasPlayed {
            report(episode: outgoing, seconds: lastTime)
        }
        trackedEpisode = episode
        // Playing it again is her overruling herself, and positions should
        // start being written for it once more. Otherwise an episode marked
        // played would never remember a position again.
        if let episode { filedByHand.remove(episode.id) }
        lastTime = episode?.positionSeconds ?? 0
        hasPlayed = false
    }

    func episodeFiled(_ change: EpisodeFiling.Change) {
        if change.filing.hidesFromLatest {
            filedByHand.insert(change.episodeID)
        } else {
            filedByHand.remove(change.episodeID)
        }
    }

    func playingChanged(_ playing: Bool) {
        if playing {
            hasPlayed = true
        } else {
            // Covers pause, AirPods pause, "Hey Siri pause", and stalls.
            flush()
        }
    }

    func timeTicked(to time: TimeInterval) {
        guard trackedEpisode != nil else { return }
        let jumped = abs(time - lastTime) > Self.seekJumpThreshold
        lastTime = time
        // While paused, a "jump" is just a scrub preview; the eventual pause
        // flush or background flush records wherever she settles.
        guard hasPlayed, player.isPlaying else { return }
        if jumped || Date().timeIntervalSince(lastReportAt) > Self.heartbeatInterval {
            flush()
        }
    }

    func flush() {
        guard hasPlayed, let episode = trackedEpisode else { return }
        report(episode: episode, seconds: lastTime)
    }

    private func report(episode: Episode, seconds: TimeInterval) {
        guard !filedByHand.contains(episode.id) else { return }
        lastReportAt = Date()
        let duration = player.duration
        let completed = duration > 0 && seconds / duration > 0.95
        let api = self.api
        Task { try? await api.reportPosition(episodeID: episode.id, seconds: seconds, completed: completed) }
    }
}
