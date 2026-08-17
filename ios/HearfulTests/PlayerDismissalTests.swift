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
            article: ArticlePlayer(api: api, synthesizer: synthesizer))
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
        let reporter = PositionReporter(api: api, player: coordinator)
        try coordinator.play(article())
        await waitUntilLoaded(coordinator)

        synthesizer.finishSpeaking()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(reporter.trackedEpisode == nil)
        #expect(api.reportedPositions.last?.episodeID == 1)
        #expect(api.reportedPositions.last?.completed == true)
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
