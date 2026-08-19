import Foundation
import Testing

@testable import Hearful

@Suite("Playback failures")
@MainActor
struct PlaybackFailureTests {
    private func episode() -> Episode {
        Episode(
            id: 818,
            title: "The missing episode",
            description: nil,
            audioURL: URL(string: "https://audio.example.com/missing.mp3"),
            durationSeconds: 1_800,
            publishedAt: nil,
            link: nil,
            imageURL: nil,
            positionSeconds: nil,
            completed: nil,
            hasText: false)
    }

    @Test func anAsynchronousAudioFailureReachesTheCoordinator() {
        let audio = AudioPlayer()
        let coordinator = PlaybackCoordinator(audio: audio, article: ArticlePlayer())
        let item = episode()
        audio.restore(item)

        audio.reportFailure(for: item, underlying: "HTTP 404")

        #expect(coordinator.playbackFailure?.episode.id == item.id)
        #expect(coordinator.playbackFailure?.message.contains("try again") == true)
    }

    @Test func dismissingTheExplanationClearsIt() {
        let audio = AudioPlayer()
        let coordinator = PlaybackCoordinator(audio: audio, article: ArticlePlayer())
        let item = episode()
        audio.restore(item)
        audio.reportFailure(for: item, underlying: "offline")

        coordinator.dismissPlaybackFailure()

        #expect(coordinator.playbackFailure == nil)
    }
}
