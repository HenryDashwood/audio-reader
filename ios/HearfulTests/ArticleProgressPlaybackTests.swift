import Foundation
import Testing
@testable import Hearful

private actor BookmarkPlaybackAPI: HearfulAPIProtocol {
    let body = "Café 🌱 in the garden.\n\nAnother 🦉 passage beside the river.\n\nThe final paragraph."
    var revision = String(repeating: "a", count: 64)
    var bookmark: ArticleBookmark?
    var completed = false
    var offline = false
    var failReports = false
    var records: [ArticleProgressReport] = []
    var reportedEpisodeIDs: [Int] = []
    var accepted: [String: (ArticleProgressReport, String)] = [:]
    var legacyReports = 0
    var selectedContent = 7
    var changedText: String?
    var overrideReceipt: ArticleProgressReceipt?
    var text: String { changedText ?? body }
    func setOffline(_ value: Bool) { offline = value }
    func failProgressReports() { failReports = true }
    func setBookmark(_ offset: Int, revision: String) {
        bookmark = .init(textVersion: ArticleScript.textVersion(text), offsetUTF16: offset); self.revision = revision
    }
    func setReplacement() {
        changedText = "A new 🐦 captured article."; selectedContent = 8; bookmark = nil; revision = String(repeating: "c", count: 64)
    }
    func reports() -> [ArticleProgressReport] { records }
    func reportEpisodeIDs() -> [Int] { reportedEpisodeIDs }
    func legacyCount() -> Int { legacyReports }
    func episode(id: Int) async throws -> Episode {
        if offline { throw URLError(.notConnectedToInternet) }
        return row(id)
    }
    func row(_ id: Int = 1) -> Episode {
        Episode(id: id, title: "Article", description: nil, audioURL: nil, durationSeconds: nil,
            publishedAt: nil, link: nil, positionSeconds: 120, articleBookmark: bookmark, completed: completed,
            hasText: true, contentID: selectedContent)
    }
    func articleText(episodeID: Int) async throws -> EpisodeText { try await articleText(episodeID: episodeID, contentID: selectedContent) }
    func articleText(episodeID: Int, contentID: Int?) async throws -> EpisodeText {
        if offline { throw URLError(.notConnectedToInternet) }
        return EpisodeText(episodeID: episodeID, contentID: selectedContent, title: "Article", text: text,
            articleProgress: .init(textVersion: ArticleScript.textVersion(text), contentID: selectedContent, revision: revision, bookmark: bookmark))
    }
    func reportArticleProgress(episodeID: Int, report: ArticleProgressReport) async throws -> ArticleProgressReceipt {
        records.append(report)
        reportedEpisodeIDs.append(episodeID)
        if offline || failReports { throw URLError(.networkConnectionLost) }
        if let overrideReceipt { return overrideReceipt }
        if let prior = accepted[report.requestID] {
            guard prior.0 == report else { throw APIError(underlying: "Reused request", statusCode: 409) }
            return .init(episode: row(episodeID), progress: .init(textVersion: ArticleScript.textVersion(text),
                contentID: selectedContent, revision: revision, bookmark: bookmark), acceptedRevision: prior.1)
        }
        guard report.expectedRevision == revision, report.textVersion == ArticleScript.textVersion(text), report.contentID == selectedContent
        else { throw APIError(underlying: "Progress changed", statusCode: 409) }
        bookmark = .init(textVersion: report.textVersion, offsetUTF16: report.offsetUTF16)
        completed = report.completed
        revision = ArticleScript.textVersion(report.requestID)
        accepted[report.requestID] = (report, revision)
        return .init(episode: row(episodeID), progress: .init(textVersion: ArticleScript.textVersion(text),
            contentID: selectedContent, revision: revision, bookmark: bookmark), acceptedRevision: revision)
    }
    func setConflict() {
        completed = true; revision = String(repeating: "c", count: 64); bookmark = nil
        overrideReceipt = .init(episode: row(), progress: .init(textVersion: ArticleScript.textVersion(text),
            contentID: selectedContent, revision: revision, bookmark: nil), acceptedRevision: String(repeating: "b", count: 64))
    }
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool, durationSeconds: Int?) async throws { legacyReports += 1 }
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws { legacyReports += 1 }
    func command(transcript: String, nowPlayingEpisodeID: Int?, turns: [ConversationTurn], traceparent: String?) async throws -> CommandResponse { throw APIError(underlying: "Unused") }
    func recentEpisodes(limit: Int) async throws -> [Episode] { [] }
    func shows() async throws -> [Show] { [] }
    func episodes(showID: Int, query: String?) async throws -> [Episode] { [] }
    func searchPodcasts(query: String) async throws -> [PodcastResult] { [] }
    func previewFeed(url: URL) async throws -> FeedPreview { throw APIError(underlying: "Unused") }
    func subscribe(feedURL: URL) async throws -> Show { throw APIError(underlying: "Unused") }
    func unsubscribe(showID: Int) async throws { }
    func login(appleIdentityToken: String, authorizationCode: String?) async throws -> AuthResponse { throw APIError(underlying: "Unused") }
    func logout() async throws { }
    func me() async throws -> UserInfo { .init(id: "test", displayName: nil) }
    func deleteAccount() async throws { }
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String?) async throws { }
    func reportDiagnostic(_ event: [String: any Sendable]) async throws { }
}

@Suite("Shared article playback")
@MainActor
struct ArticleProgressPlaybackTests {
    private let owner = String(repeating: "d", count: 64)
    // These tests control responses, not elapsed time. A loaded CI runner must
    // not race their mock replies against the production cache deadline.
    private let loadDeadline = ControlledDelay()
    private func loaded(_ player: ArticlePlayer) async throws {
        await player.waitForPendingLoad()
        try #require(player.isReadyToPlay); try #require(player.loadingError == nil)
    }

    @Test(arguments: [true, false])
    func loadDeadlineFallsBackOnlyWhenTextIsCached(hasCachedText: Bool) async throws {
        let api = BookmarkPlaybackAPI()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OfflineCache(directory: directory)
        if hasCachedText { cache.saveArticle(try await api.articleText(episodeID: 1)) }
        let synth = SilentSynthesizer()
        let requestStarted = CommandGate()
        let releaseRequest = CommandGate()
        var deadline: Duration?
        let player = ArticlePlayer(
            api: api, cache: cache, synthesizer: synth, progressScope: { nil }, activateAudioSession: {},
            loadDeadlineSleep: { duration in
                deadline = duration
                // Expire only after reconciliation starts, without waiting for
                // wall time or depending on which task the runner schedules first.
                await requestStarted.wait()
            })
        player.progressDrain = {
            await requestStarted.release()
            await releaseRequest.wait()
        }

        player.play(try await api.episode(id: 1))
        await player.waitForPendingLoad()
        await releaseRequest.release()

        #expect(deadline == .seconds(hasCachedText ? 2 : 20))
        #expect(player.isReadyToPlay == hasCachedText)
        #expect(player.isPlaying == hasCachedText)
        if hasCachedText {
            #expect(player.loadingError == nil)
            #expect(synth.lastSpoken?.hasPrefix("Café") == true)
            #expect(player.progressContext?.progress.textVersion == ArticleScript.textVersion(api.body))
        } else {
            #expect(player.loadingError != nil)
            #expect(player.progressContext == nil)
        }
        player.clear()
    }

    @Test func freshPlayUsesExactRemoteTextCoordinateInsteadOfEstimatedSecondsOrCachedBookmark() async throws {
        let api = BookmarkPlaybackAPI(); let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OfflineCache(directory: directory)
        cache.save(try await api.articleText(episodeID: 1), for: .articleVersion(episodeID: 1, contentID: 7))
        let offset = (api.body as NSString).range(of: "🦉").location
        await api.setBookmark(offset, revision: String(repeating: "c", count: 64))
        let synth = SilentSynthesizer()
        let player = ArticlePlayer(api: api, cache: cache, synthesizer: synth, progressScope: { nil }, activateAudioSession: {},
            loadDeadlineSleep: { try await loadDeadline.wait(for: $0) })
        player.play(try await api.episode(id: 1)); try await loaded(player)
        #expect(synth.lastSpoken?.hasPrefix("Another") == true)
        #expect(player.progressContext?.offsetUTF16 == (api.body as NSString).range(of: "Another").location)
        #expect(player.currentTime < 120)
    }
    @Test func offlinePausePersistsExactRequestAndFreshObjectsResumeTheSamePassage() async throws {
        let api = BookmarkPlaybackAPI(); let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OfflineCache(directory: directory.appending(path: "text"))
        let store = FileArticleProgressStorage(directory: directory.appending(path: "progress"))
        let journal = ArticleProgressJournal(store: store); let synth = SilentSynthesizer()
        let player = ArticlePlayer(api: api, cache: cache, synthesizer: synth, bookmarkJournal: journal, progressScope: { owner }, activateAudioSession: {},
            loadDeadlineSleep: { try await loadDeadline.wait(for: $0) })
        let sync = ArticleProgressSync(api: api, player: player)
        defer { sync.invalidate() }
        player.prepare(try await api.episode(id: 1)); try await loaded(player)
        await sync.waitForPendingReports(); #expect(await api.reports().isEmpty)
        await api.setOffline(true)
        player.resume(); synth.finishSpeaking(); synth.speak(range: NSRange(location: 8, length: 1)); player.pause()
        await sync.waitForPendingReports()
        let stored = try #require(journal.entries(owner: owner).first)
        #expect(stored.latest.offsetUTF16 > 20)
        #expect(stored.pending != nil)
        sync.invalidate(); player.clear()
        let freshJournal = ArticleProgressJournal(store: FileArticleProgressStorage(directory: store.directory))
        let freshSynth = SilentSynthesizer()
        let fresh = ArticlePlayer(api: api, cache: cache, synthesizer: freshSynth, bookmarkJournal: freshJournal, progressScope: { owner }, activateAudioSession: {},
            loadDeadlineSleep: { try await loadDeadline.wait(for: $0) })
        let freshSync = ArticleProgressSync(api: api, player: fresh); defer { freshSync.invalidate() }
        let episode = Episode(id: 1, title: "Article", description: nil, audioURL: nil, durationSeconds: nil,
            publishedAt: nil, link: nil, positionSeconds: 0, completed: false, hasText: true, contentID: 7)
        fresh.play(episode); try await loaded(fresh)
        #expect(freshSynth.lastSpoken?.hasPrefix("Another") == true)
        await freshSync.waitForPendingReports()
        #expect(await api.reports().allSatisfy { $0 == stored.pending })
        await api.setOffline(false); fresh.pause(); await freshSync.waitForPendingReports()
        freshSync.retry(); await freshSync.waitForPendingReports()
        #expect(try freshJournal.entries(owner: owner).first?.pending == nil)
        #expect(await api.legacyCount() == 0)
    }
    @Test func completionReportsFinalTextCoordinateWithoutLegacySeconds() async throws {
        let api = BookmarkPlaybackAPI(); let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ArticleProgressJournal(store: FileArticleProgressStorage(directory: directory.appending(path: "progress")))
        let synth = SilentSynthesizer()
        let article = ArticlePlayer(api: api, cache: OfflineCache(directory: directory.appending(path: "text")), synthesizer: synth,
            bookmarkJournal: journal, progressScope: { owner }, activateAudioSession: {},
            loadDeadlineSleep: { try await loadDeadline.wait(for: $0) })
        let coordinator = PlaybackCoordinator(audio: AudioPlayer(), article: article)
        let reporter = PositionReporter(api: api, player: coordinator, sessionScope: { nil })
        defer { reporter.invalidate() }
        try coordinator.play(try await api.episode(id: 1)); try await loaded(article)
        synth.finishSpeaking(); synth.finishSpeaking(); synth.finishSpeaking()
        await reporter.waitForPendingReports()
        // Completion may sit behind a request already sent at the start. A
        // foreground retry drains that exact head before the final sample.
        let sync = ArticleProgressSync(api: api, player: article); defer { sync.invalidate() }
        await sync.waitForPendingReports()
        let last = try #require(await api.reports().last)
        #expect(last.completed); #expect(last.offsetUTF16 == (api.body).utf16.count)
        #expect(last.textVersion == ArticleScript.textVersion(api.body))
        #expect(coordinator.currentEpisode == nil); #expect(await api.legacyCount() == 0)
    }
    @Test func switchingArticlesKeepsTheOutgoingTextAndEpisodeInItsPendingReport() async throws {
        let api = BookmarkPlaybackAPI(); let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ArticleProgressJournal(store: FileArticleProgressStorage(directory: directory.appending(path: "progress")))
        let synth = SilentSynthesizer()
        let player = ArticlePlayer(api: api, cache: OfflineCache(directory: directory.appending(path: "text")), synthesizer: synth,
            bookmarkJournal: journal, progressScope: { owner }, activateAudioSession: {},
            loadDeadlineSleep: { try await loadDeadline.wait(for: $0) })
        let sync = ArticleProgressSync(api: api, player: player); defer { sync.invalidate() }
        await api.failProgressReports()
        player.play(try await api.episode(id: 1)); try await loaded(player)
        synth.finishSpeaking(); synth.speak(range: NSRange(location: 8, length: 1))
        let outgoing = try #require(player.progressContext)
        await api.setReplacement()
        player.play(try await api.episode(id: 2)); try await loaded(player)
        await sync.waitForPendingReports()
        let rows = try journal.entries(owner: owner)
        let previous = try #require(rows.first { $0.episodeID == 1 })
        #expect(previous.latest == outgoing.sample)
        #expect(previous.pending?.textVersion == ArticleScript.textVersion(api.body))
        #expect(previous.pending?.contentID == 7)
        #expect(player.progressContext?.episodeID == 2)
        #expect(player.progressContext?.progress.contentID == 8)
        #expect(await api.reportEpisodeIDs().allSatisfy { $0 == 1 })
        #expect(await api.reports().allSatisfy { $0.textVersion == ArticleScript.textVersion(api.body) && $0.contentID == 7 })
    }
    @Test func changedSavedSelectionStartsNewTextAndNewerFilingBlocksLateSamples() async throws {
        let api = BookmarkPlaybackAPI(); let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ArticleProgressJournal(store: FileArticleProgressStorage(directory: directory.appending(path: "progress")))
        let player = ArticlePlayer(api: api, cache: OfflineCache(directory: directory.appending(path: "text")), synthesizer: SilentSynthesizer(),
            bookmarkJournal: journal, progressScope: { owner }, activateAudioSession: {},
            loadDeadlineSleep: { try await loadDeadline.wait(for: $0) })
        let sync = ArticleProgressSync(api: api, player: player); defer { sync.invalidate() }
        player.play(try await api.episode(id: 1)); try await loaded(player)
        player.pause(); await sync.waitForPendingReports()
        await api.setReplacement()
        player.play(player.currentEpisode!); try await loaded(player)
        #expect(player.currentEpisode?.contentID == 8)
        #expect(player.progressContext?.progress.textVersion == ArticleScript.textVersion("A new 🐦 captured article."))
        await sync.waitForPendingReports(); await api.setConflict()
        player.pause(); await sync.waitForPendingReports()
        #expect(try journal.entries(owner: owner).first?.blocked == true)
        #expect(player.progressError?.contains("another device") == true)
        let count = await api.reports().count
        player.resume(); player.pause(); await sync.waitForPendingReports()
        #expect(await api.reports().count == count)
    }
}
