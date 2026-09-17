import Combine
import Foundation
import UIKit

/// Owns reporting separately from narration. A report carries the outgoing text
/// identity; neither a later selection nor a new account can lend it credentials.
@MainActor
final class ArticleProgressSync {
    private let api: HearfulAPIProtocol
    private let player: ArticlePlayer
    private let journal: ArticleProgressJournal
    private let owner: String?
    private var active = true
    private var cancellables: Set<AnyCancellable> = []
    private var upload: Task<Void, Never>?
    private var lastDiskWrite = Date.distantPast
    private var lastUpload = Date.distantPast

    init(api: HearfulAPIProtocol, player: ArticlePlayer) {
        self.api = api; self.player = player; journal = player.bookmarkJournal; owner = player.progressScope()
        player.progressEvents.sink { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .hearfulEpisodeFiled).sink { [weak self] note in
            guard let change = note.object as? EpisodeFiling.Change else { return }
            MainActor.assumeIsolated { self?.filed(change.episodeID) }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let context = self.player.progressContext { self.receive(.sample(context, flush: true)) }
                self.retry()
            }
        }.store(in: &cancellables)
        Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.retry() }
        }.store(in: &cancellables)
        player.progressDrain = { [weak self] in await self?.waitForPendingReports() }
        retry()
    }
    private var valid: Bool { active && owner != nil && player.progressScope() == owner }
    func invalidate() {
        active = false; upload?.cancel(); upload = nil; cancellables.removeAll()
    }
    func waitForPendingReports() async { await upload?.value }

    private func receive(_ event: ArticlePlaybackEvent) {
        guard valid, let owner else { return }
        do {
            switch event {
            case .prepared(let context):
                try journal.start(owner: owner, episodeID: context.episodeID, playbackID: context.playbackID,
                    progress: context.progress, sample: context.sample)
                lastDiskWrite = .distantPast
            case .sample(let context, let flush):
                guard context.hasPlayed else { return }
                guard flush || Date().timeIntervalSince(lastDiskWrite) >= 3 else { return }
                if try journal.record(owner: owner, episodeID: context.episodeID, playbackID: context.playbackID, sample: context.sample) {
                    lastDiskWrite = Date()
                    NotificationCenter.default.post(name: .hearfulPositionReported, object: PositionReport(
                        episodeID: context.episodeID, seconds: player.currentTime, completed: context.completed,
                        durationSeconds: nil, contentID: context.progress.contentID))
                }
                if flush || Date().timeIntervalSince(lastUpload) >= 30 { retry() }
            }
        } catch {
            player.progressError = "Your listening position could not be saved. Check the available storage and try again."
        }
    }
    private func filed(_ episodeID: Int) {
        guard valid, let owner else { return }
        do { try journal.block(owner: owner, episodeIDs: [episodeID]) }
        catch { player.progressError = "Your listening progress could not be updated." }
    }
    func retry() {
        guard valid, let owner, upload == nil else { return }
        lastUpload = Date()
        upload = Task { [weak self] in
            guard let self else { return }
            defer { self.upload = nil }
            do {
                var observed: ArticleProgressState?
                var observedPlayback: UUID?
                try await journal.flush(owner: owner, valid: { self.valid }, send: { id, report in
                    observed = self.player.cachedArticleProgress(episodeID: id, contentID: report.contentID)
                    observedPlayback = self.player.progressContext?.playbackID
                    do { return try await self.api.reportArticleProgress(episodeID: id, report: report) }
                    catch let error as APIError {
                        guard self.valid else { throw CancellationError() }
                        if error.statusCode == 409 {
                            let episode = try await self.api.episode(id: id)
                            guard self.valid else { throw CancellationError() }
                            let text = try await self.api.articleText(episodeID: id, contentID: episode.contentID)
                            guard self.valid else { throw CancellationError() }
                            if let progress = text.articleProgress, progress.isValid {
                                return ArticleProgressReceipt(episode: episode, progress: progress, acceptedRevision: "")
                            }
                            try self.journal.block(owner: owner, episodeIDs: [id])
                        }
                        if [403, 404, 422].contains(error.statusCode ?? 0) {
                            try self.journal.block(owner: owner, episodeIDs: [id])
                        }
                        throw error
                    }
                }, applied: { receipt in
                    guard self.valid else { return }
                    self.player.acceptArticleProgress(receipt, replacing: observed, playbackID: observedPlayback)
                    if receipt.changedSinceAcceptance {
                        if (try? self.journal.entries(owner: owner).first { $0.episodeID == receipt.episode.id }?.blocked) == true {
                            NotificationCenter.default.post(name: .hearfulPositionReported, object: PositionReport(
                                episodeID: receipt.episode.id, seconds: receipt.episode.positionSeconds ?? 0,
                                completed: receipt.episode.completed ?? false, durationSeconds: nil, contentID: receipt.episode.contentID))
                        }
                        self.player.progressError = "This article changed on another device. Its newer progress was kept. Choose Play again to continue here."
                    } else { self.player.progressError = nil }
                })
            } catch is CancellationError { }
            catch {
                if self.valid { self.player.progressError = "Your listening position is saved on this device and will sync when connected." }
            }
        }
    }
}
