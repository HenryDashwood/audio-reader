import Foundation
import Testing

@testable import Hearful

/// Emptying the player: by hand, and when an episode simply runs out.
///
/// The bug behind these: there was no way at all to put the mini player away.
/// It sat above the tab bar on every screen, and finishing an episode left it
/// there too, holding an item stopped on its own last second.
@MainActor
@Suite("Dismissing the player")
struct PlayerDismissalTests {
    /// One paragraph, so a single chunk: finishing it finishes the article.
    private func makeCoordinator() -> (PlaybackCoordinator, SilentSynthesizer, FakeAPI) {
        let api = FakeAPI()
        api.articleText = "One short paragraph, read out as a single chunk."
        let synthesizer = SilentSynthesizer()
        let coordinator = PlaybackCoordinator(
            audio: AudioPlayer(),
            article: ArticlePlayer(
                api: api,
                // Completion must use this test's one-paragraph fixture, not
                // an article another parallel test wrote to the shared cache.
                cache: OfflineCache(directory: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                synthesizer: synthesizer))
        return (coordinator, synthesizer, api)
    }

    private func article(id: Int = 1) -> Episode {
        Episode(
            id: id, title: "An article", description: nil, audioURL: nil, durationSeconds: nil,
            publishedAt: nil, link: nil, imageURL: nil, positionSeconds: nil, completed: nil,
            hasText: true)
    }

    private func podcast(id: Int = 2) -> Episode {
        Episode(
            id: id, title: "An episode", description: nil,
            audioURL: URL(string: "https://cdn.example.com/\(id).mp3"), durationSeconds: 3600,
            publishedAt: nil, link: nil)
    }

    /// The text arrives on a Task, so `play` returns before there is anything
    /// to read; everything below depends on it having landed.
    private func waitUntilLoaded(_ coordinator: PlaybackCoordinator) async {
        for _ in 0..<100 where coordinator.article.duration == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func closingByHandEmptiesThePlayer() async throws {
        let (coordinator, _, _) = makeCoordinator()
        try coordinator.play(article())
        await waitUntilLoaded(coordinator)
        #expect(coordinator.currentEpisode != nil, "nothing loaded; the test proves nothing")
        #expect(coordinator.isPlaying, "nothing was playing; the test proves nothing")

        coordinator.clear()

        #expect(coordinator.currentEpisode == nil)
        #expect(!coordinator.isPlaying)
        #expect(!coordinator.article.isPlaying)
        #expect(coordinator.currentTime == 0)
    }

    @Test func closingByHandEmptiesTheLoadedPodcastToo() {
        // Restored rather than played: loading is all this needs, and playing
        // for real would want an audio session and a network.
        let (coordinator, _, _) = makeCoordinator()
        coordinator.restore(podcast())
        #expect(coordinator.currentEpisode?.id == 2, "nothing loaded; the test proves nothing")

        coordinator.clear()

        #expect(coordinator.currentEpisode == nil)
        #expect(coordinator.audio.currentEpisode == nil)
    }

    @Test func reachingTheEndOfAnArticlePutsThePlayerAway() async throws {
        let (coordinator, synthesizer, _) = makeCoordinator()
        try coordinator.play(article())
        await waitUntilLoaded(coordinator)
        #expect(coordinator.currentEpisode != nil, "nothing loaded; the test proves nothing")

        synthesizer.finishSpeaking()

        #expect(coordinator.currentEpisode == nil)
        #expect(!coordinator.isPlaying)
    }

    @Test func theFinishedEpisodeIsFiledBeforeThePlayerIsEmptied() async throws {
        // The ordering trap inside clear(): winding the clock back before
        // publishing the episode as nil would have the position reporter file
        // something she has just heard to the end as unplayed.
        let (coordinator, synthesizer, api) = makeCoordinator()
        // Held for the length of the test: it works purely by observing.
        let reporter = PositionReporter(api: api, player: coordinator, sessionScope: { nil })
        // Make an older incomplete update finish slowly. Without the reporter's
        // ordering guarantee it would arrive after the completion update and
        // put the episode back into an unfinished state.
        api.incompletePositionReportDelay = .milliseconds(50)
        try coordinator.play(article())
        await waitUntilLoaded(coordinator)

        synthesizer.finishSpeaking()
        await reporter.waitForPendingReports()

        #expect(reporter.trackedEpisode == nil)
        #expect(api.reportedPositions.last?.episodeID == 1)
        #expect(api.reportedPositions.last?.completed == true)
    }

    @Test(arguments: [0.96, 1.0, 1.1])
    func podcastPositionAloneNeverCompletesPlayback(fraction: Double) async {
        let (coordinator, _, api) = makeCoordinator()
        let reporter = PositionReporter(api: api, player: coordinator, sessionScope: { nil })
        coordinator.restore(podcast())
        // Drive the clock without streaming an external audio asset. Even a
        // position beyond an inaccurate duration is not an end-of-audio event.
        #expect(coordinator.duration == 3600)
        reporter.playingChanged(true)
        reporter.timeTicked(to: coordinator.duration * fraction)
        reporter.flush()
        reporter.playingChanged(false)
        coordinator.clear()
        await reporter.waitForPendingReports()

        #expect(!api.reportedPositions.isEmpty)
        #expect(api.reportedPositions.allSatisfy { !$0.completed })
        #expect(api.reportedPositions.last?.seconds == 3600 * fraction)
    }

    @Test func podcastEndCompletesEvenWhenTheDurationIsInaccurate() async {
        let (coordinator, _, api) = makeCoordinator()
        let reporter = PositionReporter(api: api, player: coordinator, sessionScope: { nil })
        coordinator.restore(podcast())
        reporter.playingChanged(true)
        reporter.timeTicked(to: 120)
        reporter.flush()

        coordinator.audio.finished.send()
        reporter.flush()
        await reporter.waitForPendingReports()

        #expect(coordinator.currentEpisode == nil)
        #expect(api.reportedPositions.last?.episodeID == 2)
        #expect(api.reportedPositions.last?.completed == true)
        #expect(api.reportedPositions.filter(\.completed).count == 1)
    }

    @Test func articleStaysUnfinishedUntilTheLastUtteranceFinishes() async throws {
        let (coordinator, synthesizer, api) = makeCoordinator()
        let reporter = PositionReporter(api: api, player: coordinator, sessionScope: { nil })
        try coordinator.play(article())
        await waitUntilLoaded(coordinator)
        #expect(coordinator.isPlaying)

        synthesizer.speakOn(toFraction: 0.99)
        #expect(coordinator.currentTime / coordinator.duration > 0.95)
        reporter.flush()
        coordinator.pause()
        await reporter.waitForPendingReports()
        #expect(!api.reportedPositions.isEmpty)
        #expect(api.reportedPositions.allSatisfy { !$0.completed })
        #expect(coordinator.currentEpisode?.id == 1)

        coordinator.resume()
        synthesizer.finishSpeaking()
        await reporter.waitForPendingReports()
        #expect(coordinator.currentEpisode == nil)
        #expect(api.reportedPositions.last?.completed == true)
        #expect(api.reportedPositions.filter(\.completed).count == 1)
    }

    @Test func closingAnArticleNearTheEndLeavesItUnfinished() async throws {
        let (coordinator, synthesizer, api) = makeCoordinator()
        let reporter = PositionReporter(api: api, player: coordinator, sessionScope: { nil })
        try coordinator.play(article())
        await waitUntilLoaded(coordinator)
        synthesizer.speakOn(toFraction: 0.99)
        #expect(coordinator.currentTime / coordinator.duration > 0.95)

        coordinator.clear()
        await reporter.waitForPendingReports()

        #expect(!api.reportedPositions.isEmpty)
        #expect(api.reportedPositions.allSatisfy { !$0.completed })
    }

    @Test func closingForgetsTheEpisodeSoItIsNotBackNextLaunch() {
        let suite = "player-dismissal-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        PlaybackRestore.remember(episodeID: 104, defaults: defaults)

        PlaybackRestore.forget(defaults: defaults)

        #expect(defaults.integer(forKey: PlaybackRestore.lastEpisodeKey) == 0)
    }
}
