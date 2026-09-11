import Foundation
import MediaPlayer
import Testing

@testable import Hearful

@Suite("System playback metadata")
@MainActor
struct NowPlayingTests {
    private func episode(_ id: Int, article: Bool) -> Episode {
        Episode(
            id: id, title: article ? "An article" : "A podcast", description: nil,
            audioURL: article ? nil : URL(filePath: "/not-a-real-podcast.caf"),
            durationSeconds: article ? nil : 1_800, publishedAt: nil, link: nil,
            imageURL: nil, positionSeconds: nil, completed: nil, hasText: article)
    }

    @Test func inactivePodcastCannotChangeNarrationMetadata() async throws {
        let api = FakeAPI()
        api.articleText = String(repeating: "A paragraph to read aloud. ", count: 100)
        let cache = OfflineCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let article = ArticlePlayer(
            api: api, cache: cache, synthesizer: SilentSynthesizer(),
            defaults: defaults, activateAudioSession: {})
        let audio = AudioPlayer(defaults: defaults, activateAudioSession: {})
        var info: [String: Any]?
        var publications = 0
        let coordinator = PlaybackCoordinator(
            audio: audio, article: article,
            nowPlaying: NowPlayingPublisher { info = $0; publications += 1 })
        defer { coordinator.clear() }

        coordinator.restore(episode(1, article: false))
        try coordinator.play(episode(2, article: true))
        for _ in 0..<100 where !article.isPlaying {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(article.isPlaying)
        #expect(info?[MPMediaItemPropertyTitle] as? String == "An article")
        #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        let before = publications

        // These also represent updates arriving late from the previous item.
        audio.pause()
        audio.setPlaybackRate(2)
        audio.seek(to: 400)
        audio.restore(episode(3, article: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(publications == before)
        #expect(info?[MPMediaItemPropertyTitle] as? String == "An article")
        #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)

        #expect(coordinator.handleRemotePause() == .success)
        #expect(!article.isPlaying)
        #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(coordinator.handleRemotePlay() == .success)
        #expect(article.isPlaying)
        #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        coordinator.clear()
        #expect(info == nil)
        audio.setPlaybackRate(1.5)
        #expect(info == nil)
    }

    @Test func preparingArticleCannotReplaceRestoredPodcast() async throws {
        let api = FakeAPI()
        api.articleText = "The next article."
        let cache = OfflineCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let article = ArticlePlayer(api: api, cache: cache, defaults: defaults, activateAudioSession: {})
        let audio = AudioPlayer(defaults: defaults, activateAudioSession: {})
        var info: [String: Any]?
        let coordinator = PlaybackCoordinator(
            audio: audio, article: article, nowPlaying: NowPlayingPublisher { info = $0 })
        defer { coordinator.clear() }
        coordinator.restore(episode(1, article: false))
        coordinator.prepare(episode(2, article: true))
        for _ in 0..<100 where !article.isReadyToPlay {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(article.isReadyToPlay)
        #expect(info?[MPMediaItemPropertyTitle] as? String == "A podcast")
        #expect(info?[MPMediaItemPropertyPlaybackDuration] as? Double == 1_800)
        #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }
}
