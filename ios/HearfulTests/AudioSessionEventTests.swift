import AVFoundation
import Testing

@testable import Hearful

@Suite("Reading audio session notifications")
struct AudioSessionEventReaderTests {
    @Test func interruptionBeganIsRead() {
        let event = AudioSessionEventReader.interruption(from: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
        #expect(event == .interrupted)
    }

    @Test func interruptionEndedCarriesShouldResume() {
        let event = AudioSessionEventReader.interruption(from: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume
                .rawValue,
        ])
        #expect(event == .interruptionEnded(shouldResume: true))
    }

    @Test func interruptionEndedWithoutOptionsDoesNotResume() {
        // A missing options key is the system declining to recommend resuming.
        let event = AudioSessionEventReader.interruption(from: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
        ])
        #expect(event == .interruptionEnded(shouldResume: false))
    }

    @Test func junkUserInfoIsIgnored() {
        #expect(AudioSessionEventReader.interruption(from: [:]) == nil)
        #expect(AudioSessionEventReader.routeChange(from: ["nonsense": 3]) == nil)
    }

    @Test func headphonesComingOutIsRead() {
        let event = AudioSessionEventReader.routeChange(from: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason
                .oldDeviceUnavailable.rawValue
        ])
        #expect(event == .outputDeviceDisconnected)
    }

    @Test func headphonesGoingInIsNotAnEvent() {
        // Plugging in is no reason to stop what she is listening to.
        let event = AudioSessionEventReader.routeChange(from: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason
                .newDeviceAvailable.rawValue
        ])
        #expect(event == nil)
    }
}

@Suite("What to do about an interruption")
struct InterruptionPolicyTests {
    @Test func aCallPausesPlayback() {
        var policy = InterruptionPolicy()
        #expect(policy.decide(.interrupted, wantsPlayback: true) == .pause)
    }

    @Test func playbackResumesWhenTheCallEnds() {
        var policy = InterruptionPolicy()
        _ = policy.decide(.interrupted, wantsPlayback: true)
        #expect(policy.decide(.interruptionEnded(shouldResume: true), wantsPlayback: false) == .resume)
    }

    @Test func nothingResumesIfNothingWasPlaying() {
        // An alarm going off while the app sits idle must not start an episode.
        var policy = InterruptionPolicy()
        _ = policy.decide(.interrupted, wantsPlayback: false)
        #expect(policy.decide(.interruptionEnded(shouldResume: true), wantsPlayback: false) == .nothing)
    }

    @Test func theSystemDecliningToResumeIsRespected() {
        // Another app took over the audio deliberately; barging back in on top
        // of it would be worse than staying quiet.
        var policy = InterruptionPolicy()
        _ = policy.decide(.interrupted, wantsPlayback: true)
        #expect(policy.decide(.interruptionEnded(shouldResume: false), wantsPlayback: false) == .nothing)
    }

    @Test func aSecondEndingDoesNotResumeAgain() {
        var policy = InterruptionPolicy()
        _ = policy.decide(.interrupted, wantsPlayback: true)
        _ = policy.decide(.interruptionEnded(shouldResume: true), wantsPlayback: false)
        #expect(policy.decide(.interruptionEnded(shouldResume: true), wantsPlayback: true) == .nothing)
    }

    @Test func headphonesOutPauses() {
        var policy = InterruptionPolicy()
        #expect(policy.decide(.outputDeviceDisconnected, wantsPlayback: true) == .pause)
    }

    @Test func headphonesOutNeverResumesLater() {
        // The room can hear it now; an interruption ending must not put it
        // back on the speaker.
        var policy = InterruptionPolicy()
        _ = policy.decide(.interrupted, wantsPlayback: true)
        _ = policy.decide(.outputDeviceDisconnected, wantsPlayback: true)
        #expect(policy.decide(.interruptionEnded(shouldResume: true), wantsPlayback: false) == .nothing)
    }

    @Test func anInterruptionWhilePausedChangesNothing() {
        var policy = InterruptionPolicy()
        #expect(policy.decide(.interrupted, wantsPlayback: false) == .nothing)
    }
}

@Suite("Interruptions reach the player")
@MainActor
struct PlaybackInterruptionTests {
    /// Long enough that the synthesiser is still working through it when the
    /// interruption arrives.
    private static let articleText = String(
        repeating: "The Congress of Vienna redrew the map of Europe.\n\n", count: 20)

    private func makePlayer() -> (PlaybackCoordinator, FakeAPI) {
        let api = FakeAPI()
        api.articleText = Self.articleText
        return (PlaybackCoordinator(audio: AudioPlayer(), article: ArticlePlayer(api: api)), api)
    }

    private func article(id: Int = 1) -> Episode {
        Episode(
            id: id, title: "An article", description: nil, audioURL: nil, durationSeconds: nil,
            publishedAt: nil, link: nil, imageURL: nil, positionSeconds: nil, completed: nil,
            hasText: true)
    }

    /// The article text is fetched asynchronously before anything is spoken.
    private func waitUntilSpeaking(_ player: PlaybackCoordinator) async {
        for _ in 0..<100 where !player.article.isPlaying {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aCallEndingPutsTheArticleBackOn() async throws {
        // The regression this guards: deciding from isPlaying rather than from
        // intent. AVPlayer pauses itself the moment an interruption starts, so
        // by the time the notification arrives isPlaying can already be false
        // — and reading it there would conclude nothing was playing and leave
        // her episode stopped for good.
        let (player, _) = makePlayer()
        try player.play(article())
        await waitUntilSpeaking(player)
        #expect(player.article.isPlaying, "the article never started; the test proves nothing")

        player.handle(.interrupted)
        #expect(!player.article.isPlaying)

        player.handle(.interruptionEnded(shouldResume: true))
        #expect(player.article.isPlaying)
    }

    @Test func anInterruptionWithNothingPlayingStartsNothing() {
        let (player, _) = makePlayer()
        player.restore(article())

        player.handle(.interrupted)
        player.handle(.interruptionEnded(shouldResume: true))

        #expect(!player.isPlaying)
    }

    @Test func pausingHerselfSurvivesAnInterruption() async throws {
        // She stopped it before the call came in; it must stay stopped.
        let (player, _) = makePlayer()
        try player.play(article())
        await waitUntilSpeaking(player)
        player.pause()

        player.handle(.interrupted)
        player.handle(.interruptionEnded(shouldResume: true))

        #expect(!player.article.isPlaying)
    }

    @Test func headphonesOutStopsAnArticleReadingAloud() async throws {
        // AVPlayer gets the system's own pause on disconnect; the speech
        // synthesiser does not, and would carry on out loud on the speaker.
        let (player, _) = makePlayer()
        try player.play(article())
        await waitUntilSpeaking(player)

        player.handle(.outputDeviceDisconnected)

        #expect(!player.article.isPlaying)
    }

    @Test func headphonesOutIsNotUndoneByACallEnding() async throws {
        let (player, _) = makePlayer()
        try player.play(article())
        await waitUntilSpeaking(player)

        player.handle(.outputDeviceDisconnected)
        player.handle(.interruptionEnded(shouldResume: true))

        #expect(!player.article.isPlaying)
    }
}

@Suite("Article seeking")
@MainActor
struct ArticleSeekTests {
    private static let text = String(
        repeating: "The Congress of Vienna redrew the map of Europe.\n\n", count: 20)

    private func loadedPlayer() async -> ArticlePlayer {
        let api = FakeAPI()
        api.articleText = Self.text
        let player = ArticlePlayer(api: api)
        player.play(
            Episode(
                id: 1, title: "An article", description: nil, audioURL: nil,
                durationSeconds: nil, publishedAt: nil, link: nil, imageURL: nil,
                positionSeconds: nil, completed: nil, hasText: true))
        for _ in 0..<100 where !player.isPlaying {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return player
    }

    @Test func seekingWhilePlayingLandsOnTheChunk() async {
        // seek() no longer sets currentTime on this path — speakCurrentChunk
        // does. If that coupling ever breaks, the position silently stops
        // following her and the scrubber lies.
        let player = await loadedPlayer()
        #expect(player.isPlaying, "the article never started; the test proves nothing")

        player.seek(to: player.duration / 2)

        #expect(player.currentTime > 0)
        #expect(player.currentTime <= player.duration / 2)
    }

    @Test func seekingWhilePausedStillMovesThePosition() async {
        let player = await loadedPlayer()
        player.pause()

        player.seek(to: player.duration / 2)

        #expect(player.currentTime > 0)
    }

    @Test func seekingBeyondTheEndClampsRatherThanOverrunning() async {
        let player = await loadedPlayer()
        player.pause()

        player.seek(to: player.duration * 10)

        #expect(player.currentTime <= player.duration)
    }

    @Test func seekingBeforeTheStartClampsToZero() async {
        let player = await loadedPlayer()
        player.pause()

        player.seek(to: -500)

        #expect(player.currentTime >= 0)
    }
}
