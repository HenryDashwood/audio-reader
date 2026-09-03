import Foundation
import Testing

@testable import Hearful

@MainActor
@Suite("Playback speed preferences")
struct PlaybackSpeedTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "playback-speed-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func oldSharedSpeedSeedsBothPreferences() {
        let defaults = makeDefaults()
        defaults.set(1.5, forKey: PlaybackSpeedPreference.legacyKey)

        let podcast = PlaybackSpeedPreference.load(.podcast, defaults: defaults)
        let article = PlaybackSpeedPreference.load(.article, defaults: defaults)

        #expect(podcast == 1.5)
        #expect(article == 1.5)
    }

    @Test func playersRememberIndependentSpeeds() {
        let defaults = makeDefaults()
        let audio = AudioPlayer(defaults: defaults)
        let article = ArticlePlayer(
            api: FakeAPI(), synthesizer: SilentSynthesizer(), defaults: defaults)

        audio.setPlaybackRate(1.25)
        article.setPlaybackRate(1.75)

        #expect(PlaybackSpeedPreference.load(.podcast, defaults: defaults) == 1.25)
        #expect(PlaybackSpeedPreference.load(.article, defaults: defaults) == 1.75)
        #expect(AudioPlayer(defaults: defaults).playbackRate == 1.25)
        #expect(
            ArticlePlayer(
                api: FakeAPI(), synthesizer: SilentSynthesizer(), defaults: defaults
            ).playbackRate == 1.75)
    }

    @Test func coordinatorChangesOnlyTheActiveKind() {
        let defaults = makeDefaults()
        let audio = AudioPlayer(defaults: defaults)
        let article = ArticlePlayer(
            api: FakeAPI(), synthesizer: SilentSynthesizer(), defaults: defaults)
        let coordinator = PlaybackCoordinator(audio: audio, article: article)

        coordinator.setPlaybackRate(1.25)

        #expect(coordinator.podcastPlaybackRate == 1.25)
        #expect(coordinator.articlePlaybackRate == 1.0)

        coordinator.restore(
            Episode(
                id: 1, title: "An article", description: nil, audioURL: nil,
                durationSeconds: nil, publishedAt: nil, link: nil, imageURL: nil,
                positionSeconds: nil, completed: nil, hasText: true))
        coordinator.setPlaybackRate(1.75)

        #expect(coordinator.playbackRate == 1.75)
        #expect(coordinator.podcastPlaybackRate == 1.25)
        #expect(coordinator.articlePlaybackRate == 1.75)
    }

    @Test func switchingKindsImmediatelyShowsTheActiveSpeed() {
        let defaults = makeDefaults()
        let audio = AudioPlayer(defaults: defaults)
        let article = ArticlePlayer(
            api: FakeAPI(), synthesizer: SilentSynthesizer(), defaults: defaults)
        let coordinator = PlaybackCoordinator(audio: audio, article: article)
        coordinator.setPodcastPlaybackRate(2.0)
        coordinator.setArticlePlaybackRate(1.5)

        coordinator.restore(
            Episode(
                id: 1, title: "An article", description: nil, audioURL: nil,
                durationSeconds: nil, publishedAt: nil, link: nil, imageURL: nil,
                positionSeconds: nil, completed: nil, hasText: true))

        #expect(coordinator.mode == .article)
        #expect(coordinator.playbackRate == 1.5)

        // Selecting the already-active rate must not leave a stale value in
        // the Now Playing control.
        coordinator.setPlaybackRate(1.5)
        #expect(coordinator.playbackRate == 1.5)
    }
}
