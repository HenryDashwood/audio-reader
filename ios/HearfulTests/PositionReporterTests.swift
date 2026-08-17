import Foundation
import Testing

@testable import Hearful

/// Records reportPosition calls; every other method is unused here.
final class RecordingAPI: HearfulAPIProtocol, @unchecked Sendable {
    struct Report: Equatable {
        let episodeID: Int
        let seconds: Double
        let completed: Bool
    }
    var reports: [Report] = []

    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws {
        reports.append(Report(episodeID: episodeID, seconds: seconds, completed: completed))
    }

    var filings: [(episodeID: Int, played: Bool?, dismissed: Bool?)] = []
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws {
        filings.append((episodeID, played, dismissed))
    }

    var reportedAttempts: [[String: any Sendable]] = []
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String? = nil) async throws {
        reportedAttempts.append(event)
    }

    func reportDiagnostic(_ event: [String: any Sendable]) async throws {}

    func command(transcript: String, nowPlayingEpisodeID: Int? = nil, traceparent: String? = nil) async throws
        -> CommandResponse {
        CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)
    }
    func episode(id: Int) async throws -> Episode { throw APIError(underlying: "unused") }
    func recentEpisodes(limit: Int) async throws -> [Episode] { [] }
    func shows() async throws -> [Show] { [] }
    func episodes(showID: Int, query: String? = nil) async throws -> [Episode] { [] }
    func login(appleIdentityToken: String, authorizationCode: String?) async throws
        -> AuthResponse
    {
        AuthResponse(token: "t", user: UserInfo(id: "u", displayName: nil))
    }
    func logout() async throws {}
    func deleteAccount() async throws {}
    func me() async throws -> UserInfo { UserInfo(id: "u", displayName: nil) }
    func articleText(episodeID: Int) async throws -> EpisodeText {
        throw APIError(underlying: "unused")
    }
    func searchPodcasts(query: String) async throws -> [PodcastResult] { [] }
    func previewFeed(url: URL) async throws -> FeedPreview { throw APIError(underlying: "unused") }
    func subscribe(feedURL: URL) async throws -> Show { throw APIError(underlying: "unused") }
    func unsubscribe(showID: Int) async throws {}
}

private func episode(id: Int, position: Double? = nil) -> Episode {
    Episode(
        id: id, title: "Episode \(id)", description: nil,
        audioURL: URL(string: "https://cdn.example.com/\(id).mp3"),
        durationSeconds: 3600, publishedAt: nil, link: nil,
        positionSeconds: position, completed: nil)
}

/// Waits out the fire-and-forget report Task before asserting.
@MainActor
private func settle() async {
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(20))
}

@MainActor
@Suite("Position reporting")
struct PositionReporterTests {
    private func makeReporter() -> (PositionReporter, RecordingAPI) {
        let api = RecordingAPI()
        // Private player instances: idle, so their published state never
        // interferes with the handler calls below.
        let coordinator = PlaybackCoordinator(audio: AudioPlayer(), article: ArticlePlayer(api: api))
        return (PositionReporter(api: api, player: coordinator), api)
    }

    @Test func pausingReportsThePosition() async {
        let (reporter, api) = makeReporter()
        reporter.episodeChanged(to: episode(id: 104))
        reporter.playingChanged(true)
        reporter.timeTicked(to: 0.5)
        reporter.timeTicked(to: 1.0)
        reporter.playingChanged(false)
        await settle()

        #expect(api.reports.last == .init(episodeID: 104, seconds: 1.0, completed: false))
    }

    @Test func switchingEpisodesFlushesTheOutgoingOne() async {
        let (reporter, api) = makeReporter()
        reporter.episodeChanged(to: episode(id: 104))
        reporter.playingChanged(true)
        reporter.timeTicked(to: 90)
        reporter.episodeChanged(to: episode(id: 205))
        await settle()

        #expect(api.reports == [.init(episodeID: 104, seconds: 90, completed: false)])
    }

    @Test func merelyLoadingAnEpisodeReportsNothing() async {
        // prepare() without play must never overwrite a saved position with 0.
        let (reporter, api) = makeReporter()
        reporter.episodeChanged(to: episode(id: 104, position: 500))
        reporter.timeTicked(to: 0)
        reporter.flush()
        reporter.episodeChanged(to: nil)
        await settle()

        #expect(api.reports.isEmpty)
    }

    @Test func backgroundFlushReportsWhilePlaying() async {
        let (reporter, api) = makeReporter()
        reporter.episodeChanged(to: episode(id: 104))
        reporter.playingChanged(true)
        reporter.timeTicked(to: 42)
        reporter.flush()
        await settle()

        #expect(api.reports.last == .init(episodeID: 104, seconds: 42, completed: false))
    }

    @Test func aFiledEpisodeStopsReportingItsPosition() async {
        // The bug this exists to stop: she marks the episode she is listening
        // to as played, the app pauses it, the pause flushes a position, and
        // the flush works `completed` out from how far through she is — false.
        // Thirty seconds of listening would undo what she asked for, and the
        // confirmation she heard would have been a lie.
        let (reporter, api) = makeReporter()
        reporter.episodeChanged(to: episode(id: 104))
        reporter.playingChanged(true)
        reporter.timeTicked(to: 120)

        reporter.episodeFiled(.init(episodeID: 104, filing: .played))
        reporter.playingChanged(false)
        await settle()

        #expect(api.reports.isEmpty)
    }

    @Test func aDismissedEpisodeStopsReportingToo() async {
        let (reporter, api) = makeReporter()
        reporter.episodeChanged(to: episode(id: 104))
        reporter.playingChanged(true)
        reporter.timeTicked(to: 120)

        reporter.episodeFiled(.init(episodeID: 104, filing: .dismissed))
        reporter.flush()
        await settle()

        #expect(api.reports.isEmpty)
    }

    @Test func filingOneEpisodeDoesNotSilenceAnother() async {
        let (reporter, api) = makeReporter()
        reporter.episodeFiled(.init(episodeID: 999, filing: .played))
        reporter.episodeChanged(to: episode(id: 104))
        reporter.playingChanged(true)
        reporter.timeTicked(to: 42)
        reporter.flush()
        await settle()

        #expect(api.reports.last == .init(episodeID: 104, seconds: 42, completed: false))
    }

    @Test func restoringLetsItReportAgain() async {
        let (reporter, api) = makeReporter()
        reporter.episodeChanged(to: episode(id: 104))
        reporter.playingChanged(true)
        reporter.episodeFiled(.init(episodeID: 104, filing: .played))
        reporter.episodeFiled(.init(episodeID: 104, filing: .restored))
        reporter.timeTicked(to: 42)
        reporter.flush()
        await settle()

        #expect(api.reports.last == .init(episodeID: 104, seconds: 42, completed: false))
    }

    @Test func playingItAgainLetsItReportAgain() async {
        // Marking something played and then playing it anyway is her
        // overruling herself; the position has to start being kept again, or
        // that episode would never remember where she got to.
        let (reporter, api) = makeReporter()
        reporter.episodeChanged(to: episode(id: 104))
        reporter.playingChanged(true)
        reporter.episodeFiled(.init(episodeID: 104, filing: .played))

        reporter.episodeChanged(to: episode(id: 200))
        reporter.episodeChanged(to: episode(id: 104))
        reporter.playingChanged(true)
        reporter.timeTicked(to: 42)
        reporter.flush()
        await settle()

        #expect(api.reports.last == .init(episodeID: 104, seconds: 42, completed: false))
    }
}
