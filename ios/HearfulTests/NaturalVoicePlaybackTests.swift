import Foundation
import Testing

@testable import Hearful

@Suite("Natural voice playback recovery")
@MainActor
struct NaturalVoicePlaybackTests {
    private func article(id: Int = 1) -> Episode {
        Episode(
            id: id, title: "An article", description: nil, audioURL: nil,
            durationSeconds: nil, publishedAt: nil, link: nil, imageURL: nil,
            positionSeconds: nil, completed: nil, hasText: true)
    }

    private func loadedPlayer(
        initial: SilentSynthesizer,
        preferred: SilentSynthesizer,
        fallback: SilentSynthesizer
    ) async -> ArticlePlayer {
        let api = FakeAPI()
        api.articleText = "One short paragraph that must never be silently skipped."
        let player = ArticlePlayer(
            api: api,
            synthesizer: initial,
            preferredSynthesizerFactory: { preferred },
            fallbackSynthesizerFactory: { fallback })
        player.play(article())
        for _ in 0..<100 where player.duration == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return player
    }

    @Test func changingVoiceWhilePausedTakesEffectOnResume() async {
        let initial = SilentSynthesizer()
        let preferred = SilentSynthesizer()
        let fallback = SilentSynthesizer()
        let player = await loadedPlayer(
            initial: initial, preferred: preferred, fallback: fallback)
        #expect(initial.lastSpoken != nil, "the article never started; the test proves nothing")

        player.pause()
        player.voicePreferenceDidChange()
        player.resume()

        #expect(!initial.isSpeaking)
        #expect(preferred.lastSpoken == initial.lastSpoken)
        #expect(player.isPlaying)
    }

    @Test func failedNaturalSpeechRetriesTheSameChunkWithTheSystemVoice() async {
        let natural = SilentSynthesizer()
        let preferred = SilentSynthesizer()
        let system = SilentSynthesizer()
        let player = await loadedPlayer(
            initial: natural, preferred: preferred, fallback: system)
        let original = natural.lastSpoken
        #expect(original != nil, "the article never started; the test proves nothing")

        natural.failSpeaking()

        #expect(system.lastSpoken == original)
        #expect(player.currentTime == 0)
        #expect(player.isPlaying)
    }

    @Test func aDifferentArticleRetriesThePreferredNaturalVoice() async {
        let natural = SilentSynthesizer()
        let retriedNatural = SilentSynthesizer()
        let system = SilentSynthesizer()
        let player = await loadedPlayer(
            initial: natural, preferred: retriedNatural, fallback: system)
        natural.failSpeaking()
        #expect(system.lastSpoken != nil)

        player.play(article(id: 2))
        for _ in 0..<100 where !retriedNatural.isSpeaking {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(!system.isSpeaking)
        #expect(retriedNatural.isSpeaking)
    }
}
