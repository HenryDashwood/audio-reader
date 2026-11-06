import AVFoundation
import Foundation
import Testing
@testable import Hearful

/// Enforces the server's revision guard, including exact retries, without audio
/// or network timing determining when a position is acknowledged.
private actor PodcastPlaybackAPI: HearfulAPIProtocol {
    private var offline = false
    func setOffline(_ value: Bool) { offline = value }
    private var episodes: [Int: Episode] = [:]
    private var receipts: [String: (PodcastProgressReport, String)] = [:]
    private(set) var conflicts = 0

    func episode(id: Int) async throws -> Episode {
        episodes[id] ?? Episode(id: id, title: "Podcast \(id)", description: nil,
            audioURL: URL(string: "https://example.com/\(id).mp3"), durationSeconds: 3600,
            publishedAt: nil, link: nil, positionSeconds: 0,
            progressRevision: String(repeating: "a", count: 64), completed: false)
    }
    func reportPodcastProgress(episodeID: Int, report: PodcastProgressReport) async throws -> PodcastProgressReceipt {
        if offline { throw URLError(.notConnectedToInternet) }
        var episode = try await episode(id: episodeID)
        if let receipt = receipts[report.requestID] {
            #expect(receipt.0 == report)
            return .init(episode: episode, acceptedRevision: receipt.1)
        }
        guard episode.progressRevision == report.expectedRevision else {
            conflicts += 1
            throw APIError(underlying: "Progress changed", statusCode: 409)
        }
        episode.positionSeconds = report.seconds
        episode.completed = report.completed
        let revision = ArticleScript.textVersion(report.requestID)
        episode.progressRevision = revision
        episodes[episodeID] = episode
        receipts[report.requestID] = (report, revision)
        return .init(episode: episode, acceptedRevision: revision)
    }
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool, durationSeconds: Int?) async throws {
        Issue.record("A revisioned podcast must not use unguarded progress writes")
    }
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws { }
    func articleText(episodeID: Int) async throws -> EpisodeText { throw APIError(underlying: "Unused") }
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

@MainActor
@Suite("Podcast playback progress")
struct PodcastProgressPlaybackTests {
    @Test func audioPlayerLoadsTheLatestLocallyAcknowledgedPositionFromAStaleEpisode() async throws {
        let owner = ArticleScript.textVersion(UUID().uuidString)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PodcastProgressJournal(store: FilePodcastProgressStorage(directory: directory))
        let api = PodcastPlaybackAPI()
        let original = try await api.episode(id: 1)
        let playback = UUID()
        try journal.start(owner: owner, episodeID: 1, playbackID: playback,
            revision: try #require(original.progressRevision), sample: .init(seconds: 0, completed: false))
        try journal.record(owner: owner, episodeID: 1, playbackID: playback,
            sample: .init(seconds: 900, completed: false))
        try await journal.flush(owner: owner, valid: { true }, send: { id, report in
            try await api.reportPodcastProgress(episodeID: id, report: report)
        })
        let audio = AudioPlayer(defaults: .standard, activateAudioSession: {},
            podcastJournal: journal, progressScope: { owner })
        audio.localFile = { _ in URL(fileURLWithPath: "/not-a-real-podcast.wav") }
        defer { audio.clear() }
        audio.restore(original)
        #expect(audio.currentEpisode?.positionSeconds == 900)
        #expect(audio.currentEpisode?.progressRevision == (try await api.episode(id: 1)).progressRevision)
    }

    @Test(arguments: [false, true])
    func reconnectMovesPausedPodcastAndResumesNewPosition(lockScreen: Bool) async throws {
        let owner = ArticleScript.textVersion(UUID().uuidString)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "podcast.caf")
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
            buffer.frameLength = 8000
            try #require(buffer.floatChannelData)[0].update(repeating: 0, count: 8000)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<210 { try file.write(from: buffer) }
        }
        let journal = PodcastProgressJournal(store: FilePodcastProgressStorage(directory: directory))
        let api = PodcastPlaybackAPI()
        let episode = try await api.episode(id: 1)
        let engine = AVPlayer()
        let audio = AudioPlayer(defaults: .standard, player: engine, activateAudioSession: {},
            podcastJournal: journal, progressScope: { owner })
        audio.localFile = { _ in url }
        let player = PlaybackCoordinator(audio: audio, article: ArticlePlayer(progressScope: { nil }))
        let reporter = PositionReporter(api: api, player: player, sessionScope: { owner }, podcastJournal: journal)
        defer { reporter.invalidate(); player.clear() }
        await api.setOffline(true)
        try player.play(episode)
        for _ in 0..<250 where !player.isPlaying { try await Task.sleep(for: .milliseconds(20)) }
        try #require(player.isPlaying)
        player.seek(to: 60)
        player.pause()
        for _ in 0..<250 where player.isPlaying { try await Task.sleep(for: .milliseconds(20)) }
        await reporter.waitForPendingReports()
        try #require(try journal.entries(owner: owner).first?.pending != nil)
        await api.setOffline(false)
        _ = try await api.reportPodcastProgress(episodeID: 1, report: .init(requestID: UUID().uuidString,
            expectedRevision: try #require(episode.progressRevision), seconds: 180, completed: false))
        NotificationCenter.default.post(name: .hearfulRetryOffline, object: true)
        await reporter.waitForPendingReports()
        #expect(!player.isPlaying)
        #expect(player.currentTime == 180)
        if lockScreen { #expect(player.handleRemotePlay() == .success) } else { player.toggle() }
        for _ in 0..<250 {
            if player.isPlaying && engine.currentTime().seconds > 180.1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.isPlaying)
        #expect((180..<190).contains(engine.currentTime().seconds))
    }

    @Test func pausingPlayingTwoOtherEpisodesAndResumingKeepsSavingOnTheSamePhone() async throws {
        let owner = ArticleScript.textVersion(UUID().uuidString)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PodcastProgressJournal(store: FilePodcastProgressStorage(directory: directory))
        let api = PodcastPlaybackAPI()
        let coordinator = PlaybackCoordinator(audio: AudioPlayer(),
            article: ArticlePlayer(api: api, synthesizer: SilentSynthesizer(), progressScope: { nil }))
        let reporter = PositionReporter(api: api, player: coordinator, sessionScope: { owner }, podcastJournal: journal)
        defer { reporter.invalidate() }
        await reporter.waitForPendingReports()

        // The list was fetched once. Position broadcasts update its displayed
        // time, but its revision still predates this phone's acknowledged saves.
        var original = try await api.episode(id: 1)
        reporter.episodeChanged(to: original)
        reporter.playingChanged(true)
        reporter.timeTicked(to: 900)
        reporter.playingChanged(false)
        await reporter.waitForPendingReports()
        original = try #require(episodesByApplyingPositionReport([original], .init(
            episodeID: 1, seconds: 900, completed: false, durationSeconds: nil)).first)

        for id in [2, 3] {
            reporter.episodeChanged(to: try await api.episode(id: id))
            await reporter.waitForPendingReports()
            reporter.playingChanged(true)
            reporter.timeTicked(to: 120)
            reporter.playingChanged(false)
            await reporter.waitForPendingReports()
        }

        reporter.episodeChanged(to: original)
        await reporter.waitForPendingReports()
        #expect(reporter.trackedEpisode?.positionSeconds == 900)
        #expect(reporter.trackedEpisode?.progressRevision == (try await api.episode(id: 1)).progressRevision)
        reporter.playingChanged(true)
        reporter.timeTicked(to: 960)
        reporter.playingChanged(false)
        await reporter.waitForPendingReports()
        // A second save proves that resuming did not silently block the queue.
        reporter.playingChanged(true)
        reporter.timeTicked(to: 1020)
        reporter.playingChanged(false)
        await reporter.waitForPendingReports()

        #expect(await api.conflicts == 0)
        #expect(try await api.episode(id: 1).positionSeconds == 1020)
        let entry = try #require(journal.entries(owner: owner).first { $0.episodeID == 1 })
        #expect(!entry.blocked)
        #expect(entry.pending == nil)
        #expect(entry.latest.seconds == 1020)
    }
}
