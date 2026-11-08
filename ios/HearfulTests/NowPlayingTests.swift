import Foundation
import MediaPlayer
import Testing
import UIKit

@testable import Hearful

@Suite("System playback metadata")
@MainActor
struct NowPlayingTests {
    private func episode(_ id: Int, article: Bool, imageURL: URL? = nil) -> Episode {
        Episode(
            id: id, title: article ? "An article" : "A podcast", description: nil,
            audioURL: article ? nil : URL(filePath: "/not-a-real-podcast.caf"),
            durationSeconds: article ? nil : 1_800, publishedAt: nil, link: nil,
            imageURL: imageURL, positionSeconds: nil, completed: nil, hasText: article)
    }

    @Test(arguments: [false, true])
    func lateArtworkCannotRepublishAfterReplacementOrClear(clear: Bool) async throws {
        let a = URL(filePath: "/a.png")
        let b = URL(filePath: "/b.png")
        let first = episode(1, article: false, imageURL: a)
        let second = episode(2, article: true, imageURL: b)
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        var releaseFirst: CheckedContinuation<Data, Never>?
        var publications: [[String: Any]?] = []
        let publisher = NowPlayingPublisher(publish: { publications.append($0) }, loadArtwork: { url in
            if url == a {
                return await withCheckedContinuation { releaseFirst = $0 }
            }
            #expect(url == b)
            return cover
        })
        publisher.update(episode: first, isPlaying: true, elapsed: 10, duration: 100, rate: 1)
        let pending = try #require(publisher.artworkTask)
        for _ in 0..<100 where releaseFirst == nil { try await Task.sleep(for: .milliseconds(5)) }
        let firstRequest = try #require(releaseFirst)
        publisher.update(episode: second, isPlaying: true, elapsed: 20, duration: 200, rate: 1)
        await publisher.artworkTask?.value
        publisher.update(episode: second, isPlaying: false, elapsed: 23, duration: 200, rate: 1)
        let paused = try #require(publications.last ?? nil)
        #expect(paused[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        #expect(paused[MPMediaItemPropertyTitle] as? String == second.title)
        #expect(paused[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 23)
        #expect(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        if clear {
            publisher.update(episode: nil, isPlaying: false, elapsed: 0, duration: 0, rate: 1)
            #expect((publications.last ?? nil) == nil)
        }
        let count = publications.count
        firstRequest.resume(returning: cover)
        await pending.value
        #expect(publications.count == count)
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
