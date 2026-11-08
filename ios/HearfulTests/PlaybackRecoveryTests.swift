import AVFoundation
import MediaPlayer
import Testing

@testable import Hearful

@Suite("Playback recovers after Siri")
@MainActor
struct PlaybackRecoveryTests {
    private enum SessionError: Error { case siriStillActive }

    @MainActor
    private final class Session {
        var available = true
        var attempts = 0

        func activate() throws {
            attempts += 1
            if !available { throw SessionError.siriStillActive }
        }
    }

    private func podcast(url: URL = URL(fileURLWithPath: "/not-a-real-podcast.wav")) -> Episode {
        Episode(
            id: 900, title: "Interrupted podcast", description: nil,
            audioURL: url, durationSeconds: 1_800,
            publishedAt: nil, link: nil, imageURL: nil, positionSeconds: nil, completed: nil)
    }

    @Test(arguments: [3.0, 420.0, 1_795.0])
    func podcastReplacesTheInterruptedItemWithoutLosingPosition(position: Double) {
        let engine = AVPlayer()
        let audio = AudioPlayer(defaults: .standard, player: engine, activateAudioSession: {})
        audio.restore(podcast())
        audio.seek(to: position)
        let interruptedItem = engine.currentItem

        audio.pauseForInterruption()
        audio.resume()

        #expect(engine.currentItem != nil)
        #expect(engine.currentItem !== interruptedItem)
        #expect(audio.currentTime == position)
        audio.clear()
    }

    @Test func refusedActivationKeepsThePodcastAvailableForTheNextPlay() {
        let session = Session()
        session.available = false
        let engine = AVPlayer()
        let audio = AudioPlayer(defaults: .standard, player: engine, activateAudioSession: session.activate)
        audio.restore(podcast())
        audio.seek(to: 420)
        let interruptedItem = engine.currentItem
        audio.pauseForInterruption()

        audio.resume()
        #expect(engine.currentItem === interruptedItem)
        #expect(audio.currentTime == 420)
        #expect(audio.isStuckAfterPlayRequest)

        session.available = true
        audio.resume()
        #expect(engine.currentItem !== interruptedItem)
        #expect(audio.currentTime == 420)
        audio.clear()
    }

    @Test func manualPlayRetriesWhenSiriHasNotReleasedTheSession() async throws {
        let session = Session()
        session.available = false
        let url = try silentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioPlayer(defaults: .standard, activateAudioSession: session.activate)
        let coordinator = PlaybackCoordinator(audio: audio, article: ArticlePlayer())
        coordinator.restore(podcast(url: url))
        // An interruption may have no end notification. Manual Play must
        // recover without waiting for one, even if its first attempt fails.
        coordinator.handle(.interrupted)
        coordinator.resume()
        #expect(session.attempts == 1)
        for _ in 0..<100 where session.attempts < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.attempts >= 2)
        coordinator.clear()
    }

    @Test(arguments: [false, true])
    func pauseCancelsThePendingRetry(remote: Bool) async throws {
        let session = Session()
        session.available = false
        let url = try silentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioPlayer(defaults: .standard, activateAudioSession: session.activate)
        let coordinator = PlaybackCoordinator(audio: audio, article: ArticlePlayer())
        coordinator.restore(podcast(url: url))
        coordinator.resume()
        if remote {
            #expect(coordinator.handleRemotePause() == .success)
        } else {
            coordinator.pause()
        }

        try? await Task.sleep(for: .seconds(1.2))

        #expect(session.attempts == 1)
        #expect(!coordinator.isPlaying)
        coordinator.clear()
    }

    @Test(arguments: [false, true])
    func siriPauseSucceedsWhileInterruptedAndPreventsResume(shouldResume: Bool) throws {
        let session = Session()
        // Keep the transport deterministically silent, as it is when Siri
        // owns the session, while recording the user's request to play.
        session.available = false
        let url = try silentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioPlayer(defaults: .standard, activateAudioSession: session.activate)
        let coordinator = PlaybackCoordinator(audio: audio, article: ArticlePlayer())
        defer { coordinator.clear() }
        #expect(coordinator.handleRemotePause() == .noActionableNowPlayingItem)
        coordinator.restore(podcast(url: url))
        coordinator.seek(to: 0.5)
        coordinator.resume()
        coordinator.handle(.interrupted)
        #expect(!coordinator.isPlaying)
        #expect(session.attempts == 1)

        #expect(coordinator.handleRemotePause() == .success)
        #expect(coordinator.handleRemotePause() == .success)
        coordinator.handle(.interruptionEnded(shouldResume: shouldResume))

        #expect(session.attempts == 1)
        #expect(!coordinator.isPlaying)
        #expect(!audio.isStuckAfterPlayRequest)
        #expect(coordinator.currentEpisode?.id == 900)
        #expect(coordinator.currentTime == 0.5)
        coordinator.clear()
        #expect(coordinator.handleRemotePause() == .noActionableNowPlayingItem)
    }

    @Test(arguments: [false, true])
    func articleResumesOnAFreshEngineAndIgnoresRetiredCallbacks(remote: Bool) async throws {
        let oldEngine = SilentSynthesizer()
        let newEngine = SilentSynthesizer()
        let api = FakeAPI()
        api.articleText = String(repeating: "One paragraph about number fields.\n\n", count: 30)
        let session = Session()
        var replacements = 0
        let article = ArticlePlayer(
            api: api,
            cache: OfflineCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            synthesizer: oldEngine,
            makeSynthesizer: {
                replacements += 1
                return newEngine
            },
            activateAudioSession: session.activate)
        let coordinator = PlaybackCoordinator(audio: AudioPlayer(), article: article)
        let episode = Episode(
            id: 901, title: "Interrupted article", description: nil, audioURL: nil,
            durationSeconds: nil, publishedAt: nil, link: nil, imageURL: nil,
            positionSeconds: nil, completed: nil, hasText: true)
        try coordinator.play(episode)
        for _ in 0..<100 where oldEngine.spoken.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let retiredUtterance = try #require(oldEngine.spoken.last)
        oldEngine.speakOn(toFraction: 0.5)
        coordinator.handle(.interrupted)

        session.available = false
        coordinator.handle(.interruptionEnded(shouldResume: true))
        #expect(!article.isPlaying)
        #expect(article.isStuckAfterPlayRequest)
        #expect(replacements == 0)

        session.available = true
        if remote {
            #expect(coordinator.handleRemotePlay() == .success)
        } else {
            coordinator.resume()
        }
        #expect(article.isPlaying)
        #expect(replacements == 1)
        #expect(oldEngine.delegate == nil)
        #expect(newEngine.lastSpoken == retiredUtterance.speechString)
        let resumedTime = article.currentTime
        article.speechFinished(UtteranceID(retiredUtterance))
        article.speechProgressed(to: NSRange(location: 20, length: 1), of: UtteranceID(retiredUtterance))
        #expect(article.currentTime == resumedTime)
        #expect(newEngine.spoken.count == 1)
        newEngine.speakOn(toFraction: 0.5)
        #expect(article.currentTime > resumedTime)
        coordinator.clear()
    }

    @Test func articleRestartsThePassageOnAFreshEngineThenTheSystemVoiceWhenSpeechFails() async throws {
        let oldEngine = SilentSynthesizer()
        let newEngine = SilentSynthesizer()
        let thirdEngine = SilentSynthesizer()
        let systemVoice = SilentSynthesizer()
        var engines = [newEngine, thirdEngine]
        var fallbacks = 0
        let api = FakeAPI()
        api.articleText = String(repeating: "One paragraph about number fields.\n\n", count: 30)
        let article = ArticlePlayer(
            api: api,
            cache: OfflineCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            synthesizer: oldEngine,
            makeSynthesizer: { engines.removeFirst() },
            makeFallbackSynthesizer: {
                fallbacks += 1
                return systemVoice
            },
            activateAudioSession: {})
        defer { article.clear() }
        article.play(Episode(
            id: 902, title: "Route change", description: nil, audioURL: nil,
            durationSeconds: nil, publishedAt: nil, link: nil, hasText: true))
        await article.waitForPendingLoad()
        let failing = try #require(oldEngine.spoken.last)

        oldEngine.speakOn(toFraction: 0.3)  // Its first sentences play every time
        oldEngine.failSpeaking()

        #expect(article.isPlaying)
        #expect(oldEngine.delegate == nil)
        #expect(newEngine.lastSpoken == failing.speechString)

        // A second failure on the same passage, even after words were heard:
        // the system voice reads it rather than the same voice failing again.
        newEngine.speakOn(toFraction: 0.3)
        newEngine.failSpeaking()
        #expect(article.isPlaying)
        #expect(fallbacks == 1)
        #expect(systemVoice.lastSpoken == failing.speechString)
        #expect(thirdEngine.spoken.isEmpty)

        // The next passage goes back to the chosen voice.
        systemVoice.speakOn(toFraction: 0.5)
        let failedPassageTime = article.currentTime
        systemVoice.finishSpeaking()
        #expect(article.isPlaying)
        #expect(thirdEngine.spoken.count == 1)
        #expect(article.currentTime > failedPassageTime)
    }
}
