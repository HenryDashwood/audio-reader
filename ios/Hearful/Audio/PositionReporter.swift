import Combine
import UIKit

/// One report on its way to the backend.
///
/// Broadcast as `.hearfulPositionReported` before it is sent, so the lists on
/// screen can move with her instead of waiting for a reload: a row saying
/// "40 min left" an hour into the episode was the list remembering the
/// position it was fetched with.
nonisolated struct PositionReport: Equatable, Sendable {
    let episodeID: Int
    let seconds: TimeInterval
    let completed: Bool
    /// The audio's measured length, or nil while only the feed's claim is
    /// known. Never set for an article: the reader's length is an estimate
    /// at her chosen speed, not something to write over the feed's.
    let durationSeconds: Int?
    var contentID: Int? = nil
}

extension Notification.Name {
    /// Posted with a `PositionReport` as its object.
    nonisolated static let hearfulPositionReported = Notification.Name("hearfulPositionReported")
}

/// Watches playback and tells the backend where she is in each episode.
///
/// Modern article reports use a durable, source-bound text journal. Podcasts
/// and older article servers retain ordered seconds reports: a final completed
/// report must not be overtaken by an older pause or heartbeat.
@MainActor
final class PositionReporter {
    static let heartbeatInterval: TimeInterval = 30
    /// A between-tick change bigger than this is a seek, not the clock ticking.
    static let seekJumpThreshold: TimeInterval = 2.5

    private let api: HearfulAPIProtocol
    private let player: PlaybackCoordinator
    private let articleSync: ArticleProgressSync
    private let sessionScope: String?
    private let currentSessionScope: () -> String?
    private var cancellables: Set<AnyCancellable> = []

    private(set) var trackedEpisode: Episode?
    /// Episodes she has filed by hand: marked played, or put aside.
    ///
    /// Their state is hers to decide, not the clock's. Without this, marking
    /// the episode she is listening to as played is undone within seconds:
    /// pausing it flushes an incomplete position report. She would hear
    /// the confirmation, and the episode would be back in her list.
    private var filedByHand: Set<Int> = []
    private var lastTime: TimeInterval = 0
    /// Nothing is reported for an episode that was only loaded, never played:
    /// prepare() must not overwrite a saved position with zero.
    private var hasPlayed = false
    private var lastReportAt: Date = .distantPast
    private var reportQueueTail: Task<Void, Never>?
    private let podcastJournal: PodcastProgressJournal
    private var podcastUpload: Task<Void, Never>?
    private var active = true
    private var podcastSchedule = OfflineRetrySchedule()
    private var podcastPlaybackID = UUID()

    init(
        api: HearfulAPIProtocol = HearfulAPI(),
        player: PlaybackCoordinator = .shared,
        sessionScope: @escaping () -> String? = { ShortcutScope.current },
        podcastJournal: PodcastProgressJournal = .shared
    ) {
        self.api = api
        self.podcastJournal = podcastJournal
        self.player = player
        self.sessionScope = sessionScope()
        currentSessionScope = sessionScope
        articleSync = ArticleProgressSync(api: api, player: player.article)

        player.$currentEpisode
            .removeDuplicates { $0?.id == $1?.id && $0?.contentID == $1?.contentID }
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
        player.finished
            .sink { [weak self] episode in
                MainActor.assumeIsolated { self?.playbackFinished(episode) }
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
        NotificationCenter.default.publisher(for: .hearfulRetryOffline)
            .sink { [weak self] note in MainActor.assumeIsolated {
                if note.object as? Bool == true { self?.podcastSchedule.reset() }
                self?.retryPodcasts()
            } }
            .store(in: &cancellables)
        retryPodcasts()
    }

    // Internal rather than private: tests drive these directly, since
    // AudioPlayer's published state cannot be forced without real audio.

    func episodeChanged(to episode: Episode?) {
        if let episode, trackedEpisode?.id == episode.id {
            trackedEpisode = episode
            return
        }
        if let outgoing = trackedEpisode, outgoing.id != episode?.id, hasPlayed {
            report(episode: outgoing, seconds: lastTime)
        }
        trackedEpisode = episode
        podcastPlaybackID = UUID()
        if let episode, episode.audioURL != nil, let owner = sessionScope,
           let revision = episode.progressRevision, isProgressToken(revision) {
            do {
                let local = try podcastJournal.resume(owner: owner, episodeID: episode.id, revision: revision)
                try podcastJournal.start(owner: owner, episodeID: episode.id, playbackID: podcastPlaybackID,
                    revision: revision, sample: local ?? .init(seconds: episode.positionSeconds ?? 0, completed: episode.completed ?? false))
            } catch { OfflineSyncStatus.shared.report("Your listening position could not be saved. Check the available storage.") }
        }
        // Playing it again is her overruling herself, and positions should
        // start being written for it once more. Otherwise an episode marked
        // played would never remember a position again.
        if let episode { filedByHand.remove(episode.id) }
        lastTime = episode?.positionSeconds ?? 0
        hasPlayed = false
    }

    func episodeFiled(_ change: EpisodeFiling.Change) {
        if let owner = sessionScope {
            try? podcastJournal.block(owner: owner, episodeIDs: [change.episodeID])
        }
        if change.filing.hidesFromLatest {
            filedByHand.insert(change.episodeID)
        } else {
            filedByHand.remove(change.episodeID)
        }
    }

    func playingChanged(_ playing: Bool) {
        if playing {
            if let episode = trackedEpisode, let owner = sessionScope, let revision = episode.progressRevision,
               (try? podcastJournal.entries(owner: owner).first { $0.episodeID == episode.id }?.blocked) == true {
                podcastPlaybackID = UUID()
                try? podcastJournal.start(owner: owner, episodeID: episode.id, playbackID: podcastPlaybackID,
                    revision: revision, sample: .init(seconds: lastTime, completed: false))
            }
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

    private func playbackFinished(_ episode: Episode) {
        guard hasPlayed, trackedEpisode?.id == episode.id,
            trackedEpisode?.contentID == episode.contentID
        else { return }
        // Clearing the player can flush again. Do not let that overwrite the
        // final completed report with an incomplete one.
        hasPlayed = false
        report(episode: episode, seconds: lastTime, completed: true)
    }

    /// Gives tests a deterministic boundary without making playback await the
    /// network in production.
    func waitForPendingReports() async {
        await reportQueueTail?.value
        await articleSync.waitForPendingReports()
        await podcastUpload?.value
    }

    func invalidate() {
        active = false
        podcastUpload?.cancel()
        articleSync.invalidate()
        reportQueueTail?.cancel()
        cancellables.removeAll()
    }

    private func retryPodcasts() {
        guard podcastSchedule.isDue, active, let owner = sessionScope, currentSessionScope() == owner, podcastUpload == nil else { return }
        podcastUpload = Task { [weak self] in
            guard let self else { return }
            defer { self.podcastUpload = nil }
            do {
                try await podcastJournal.flush(owner: owner, valid: {
                    self.active && self.currentSessionScope() == owner
                }, send: { id, request in
                    do { return try await self.api.reportPodcastProgress(episodeID: id, report: request) }
                    catch let error as APIError {
                        if error.statusCode == 409 {
                            return PodcastProgressReceipt(episode: try await self.api.episode(id: id), acceptedRevision: "")
                        }
                        if [403, 404, 422].contains(error.statusCode ?? 0) {
                            try self.podcastJournal.block(owner: owner, episodeIDs: [id])
                        }
                        throw error
                    }
                }, applied: { receipt in
                    if self.trackedEpisode?.id == receipt.episode.id {
                        self.trackedEpisode?.progressRevision = receipt.episode.progressRevision
                        if let episode = self.trackedEpisode {
                            var saved = receipt.changedSinceAcceptance ? receipt.episode : episode
                            if !receipt.changedSinceAcceptance { saved.positionSeconds = self.lastTime }
                            PlaybackRestore.remember(saved, scope: owner)
                        }
                    }
                    if receipt.changedSinceAcceptance {
                        OfflineSyncStatus.shared.report("This episode changed on another device. Its newer listening position was kept.")
                        NotificationCenter.default.post(name: .hearfulPositionReported, object: PositionReport(
                            episodeID: receipt.episode.id, seconds: receipt.episode.positionSeconds ?? 0,
                            completed: receipt.episode.completed ?? false, durationSeconds: receipt.episode.durationSeconds))
                    }
                })
                podcastSchedule.reset()
                if (try podcastJournal.entries(owner: owner)).allSatisfy({ $0.pending == nil }),
                   OfflineSyncStatus.shared.message == "Your listening position is saved on this device and will sync when connected." {
                    OfflineSyncStatus.shared.message = nil
                }
            } catch is CancellationError { }
            catch {
                if active && currentSessionScope() == owner {
                    podcastSchedule.failed()
                    OfflineSyncStatus.shared.report("Your listening position is saved on this device and will sync when connected.")
                }
            }
        }
    }

    private func report(episode: Episode, seconds: TimeInterval, completed: Bool = false) {
        guard !filedByHand.contains(episode.id) else { return }
        // Shared text bookmarks are reported by their own source-bound journal.
        // Never let a legacy seconds write clear that newer bookmark.
        if player.article.progressContext?.episodeID == episode.id { return }
        lastReportAt = Date()
        let report = PositionReport(
            episodeID: episode.id, seconds: seconds, completed: completed,
            durationSeconds: player.measuredDuration.map { Int($0.rounded()) }, contentID: episode.contentID)
        var remembered = episode
        remembered.positionSeconds = seconds
        remembered.completed = completed
        PlaybackRestore.remember(remembered, scope: sessionScope)
        if episode.audioURL != nil, episode.progressRevision.map(isProgressToken) == true,
           let owner = sessionScope {
            do {
                if try podcastJournal.record(owner: owner, episodeID: episode.id, playbackID: podcastPlaybackID,
                    sample: .init(seconds: seconds, completed: completed)) {
                    NotificationCenter.default.post(name: .hearfulPositionReported, object: report)
                    retryPodcasts()
                }
            } catch { OfflineSyncStatus.shared.report("Your listening position could not be saved. Check the available storage.") }
            return
        }
        // Older servers retain best-effort seconds; replaying these later has
        // no revision guard and could undo a deliberate filing action.
        // The lists hear first: what she sees must not wait on the network.
        NotificationCenter.default.post(name: .hearfulPositionReported, object: report)
        let api = self.api
        let precedingReport = reportQueueTail
        let scope = sessionScope
        let currentScope = currentSessionScope
        reportQueueTail = Task {
            await precedingReport?.value
            guard !Task.isCancelled, currentScope() == scope else { return }
            try? await api.reportPosition(
                episodeID: report.episodeID, seconds: report.seconds,
                completed: report.completed, durationSeconds: report.durationSeconds, contentID: episode.contentID)
        }
    }
}
