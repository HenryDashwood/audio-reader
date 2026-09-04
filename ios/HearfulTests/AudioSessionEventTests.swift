import AVFoundation
import Testing

@testable import Hearful

private func makeAudioSessionTestCache() -> OfflineCache {
    OfflineCache(
        directory: URL.temporaryDirectory.appending(
            path: "audio-session-tests-\(UUID().uuidString)"))
}

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

    @Test func aRouteGoingAwayIsADisconnectionNotAnInterruption() {
        // Newer systems report the AirPods coming out this way, and never
        // send an end for it. Taken as an interruption, the next call ending
        // would put the episode back on through the speaker.
        let event = AudioSessionEventReader.interruption(from: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason
                .routeDisconnected.rawValue,
        ])
        #expect(event == .outputDeviceDisconnected)
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

    @Test func aCallBeginningTwiceStillResumes() {
        // One call arrives as two begins — the ring, then the answer — and by
        // the second, playback is already paused. Reading intent again there
        // concluded she had not been listening, and the call ending resumed
        // nothing.
        var policy = InterruptionPolicy()
        _ = policy.decide(.interrupted, wantsPlayback: true)
        #expect(policy.decide(.interrupted, wantsPlayback: false) == .nothing)
        #expect(policy.decide(.interruptionEnded(shouldResume: true), wantsPlayback: false) == .resume)
    }

    @Test func herTakingOverForgetsTheInterruption() {
        // A begin with no end — the app was suspended during the call. Once
        // she has pressed play herself, an unrelated end later must not start
        // the episode on its own.
        var policy = InterruptionPolicy()
        _ = policy.decide(.interrupted, wantsPlayback: true)
        policy.reset()
        #expect(policy.decide(.interruptionEnded(shouldResume: true), wantsPlayback: false) == .nothing)
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
    /// Several chunks' worth, so the interruption lands part-way through the
    /// article rather than at its end.
    private static let articleText = String(
        repeating: "The Congress of Vienna redrew the map of Europe.\n\n", count: 20)

    private func makePlayer() -> (PlaybackCoordinator, FakeAPI) {
        let api = FakeAPI()
        api.articleText = Self.articleText
        let player = PlaybackCoordinator(
            audio: AudioPlayer(),
            article: ArticlePlayer(
                api: api,
                cache: makeAudioSessionTestCache(),
                synthesizer: SilentSynthesizer()))
        return (player, api)
    }

    private func article(id: Int = 1) -> Episode {
        Episode(
            id: id, title: "An article", description: nil, audioURL: nil, durationSeconds: nil,
            publishedAt: nil, link: nil, imageURL: nil, positionSeconds: nil, completed: nil,
            hasText: true)
    }

    /// Waits for the article's text to arrive, which is what actually gates
    /// everything below: the fetch is a Task, so `play` returns before there
    /// is anything to read.
    private func waitUntilLoaded(_ player: PlaybackCoordinator) async {
        for _ in 0..<100 where player.article.duration == 0 {
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
        await waitUntilLoaded(player)
        #expect(player.article.duration > 0, "the article never loaded; the test proves nothing")

        player.handle(.interrupted)
        #expect(!player.article.isPlaying)

        player.handle(.interruptionEnded(shouldResume: true))
        #expect(player.article.isPlaying)
    }

    @Test func aCallThatBeginsTwiceStillPutsTheArticleBackOn() async throws {
        let (player, _) = makePlayer()
        try player.play(article())
        await waitUntilLoaded(player)

        player.handle(.interrupted)
        player.handle(.interrupted)
        player.handle(.interruptionEnded(shouldResume: true))

        #expect(player.article.isPlaying)
    }

    @Test func aStrandedInterruptionCannotStartHerLater() async throws {
        // No end ever came for the call; she pressed play herself, then
        // paused. When Siri's turn ends an hour later, that must not start
        // the article.
        let (player, _) = makePlayer()
        try player.play(article())
        await waitUntilLoaded(player)

        player.handle(.interrupted)
        player.resume()
        player.pause()
        player.handle(.interruptionEnded(shouldResume: true))

        #expect(!player.article.isPlaying)
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
        await waitUntilLoaded(player)
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
        await waitUntilLoaded(player)

        player.handle(.outputDeviceDisconnected)

        #expect(!player.article.isPlaying)
    }

    @Test func headphonesOutIsNotUndoneByACallEnding() async throws {
        let (player, _) = makePlayer()
        try player.play(article())
        await waitUntilLoaded(player)

        player.handle(.outputDeviceDisconnected)
        player.handle(.interruptionEnded(shouldResume: true))

        #expect(!player.article.isPlaying)
    }
}

@Suite("Reaching the end of an article")
@MainActor
struct ArticleCompletionTests {
    /// One paragraph, so a single chunk: finishing it finishes the article.
    private func reading() async -> (ArticlePlayer, SilentSynthesizer, Recorder) {
        let api = FakeAPI()
        api.articleText = "One short paragraph, read out as a single chunk."
        let synthesizer = SilentSynthesizer()
        let player = ArticlePlayer(
            api: api,
            cache: makeAudioSessionTestCache(),
            synthesizer: synthesizer)
        let recorder = Recorder()
        player.feedback = FakeFeedback(recorder)
        player.play(
            Episode(
                id: 1, title: "An article", description: nil, audioURL: nil,
                durationSeconds: nil, publishedAt: nil, link: nil, imageURL: nil,
                positionSeconds: nil, completed: nil, hasText: true))
        for _ in 0..<100 where player.duration == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (player, synthesizer, recorder)
    }

    @Test func theLastChunkFinishingLandsOnTheEnd() async {
        // The position must land exactly on the duration: the position
        // reporter reads completion off that, and an article stopping a
        // second short would never be marked as read.
        let (player, synthesizer, recorder) = await reading()
        #expect(player.duration > 0, "the article never loaded; the test proves nothing")

        synthesizer.finishSpeaking()

        #expect(player.currentTime == player.duration)
        #expect(!player.isPlaying)
        // The end must be audible: silence alone reads as a fault.
        #expect(recorder.events == [.cue(.finished)])
    }

    @Test func thePositionFollowsTheVoiceThroughAChunk() async {
        let (player, synthesizer, _) = await reading()
        #expect(player.duration > 0, "the article never loaded; the test proves nothing")

        synthesizer.speakOn(toFraction: 0.5)

        #expect(player.currentTime > 0)
        #expect(player.currentTime < player.duration)
    }

    @Test func theVisiblePositionKeepsTheVoicesExactWordRange() async {
        let (player, synthesizer, _) = await reading()
        let word = (synthesizer.lastSpoken! as NSString).range(of: "paragraph")

        synthesizer.speak(range: word)

        #expect(
            player.spokenLocation
                == ArticleSpokenLocation(episodeID: 1, rangeInArticle: word))
    }

    @Test func theVisiblePositionLeavesWhenArticleSpeechDeactivates() async {
        let (player, synthesizer, _) = await reading()
        synthesizer.speak(range: NSRange(location: 0, length: 3))
        #expect(player.spokenLocation != nil)

        player.deactivate()

        #expect(player.spokenLocation == nil)
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
        let player = ArticlePlayer(
            api: api,
            cache: makeAudioSessionTestCache(),
            synthesizer: SilentSynthesizer())
        player.play(
            Episode(
                id: 1, title: "An article", description: nil, audioURL: nil,
                durationSeconds: nil, publishedAt: nil, link: nil, imageURL: nil,
                positionSeconds: nil, completed: nil, hasText: true))
        // Waits for the text to arrive; see waitUntilLoaded above.
        for _ in 0..<100 where player.duration == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return player
    }

    @Test func seekingWhilePlayingLandsOnTheChunk() async {
        // seek() no longer sets currentTime on this path — speakCurrentChunk
        // does. If that coupling ever breaks, the position silently stops
        // following her and the scrubber lies.
        let player = await loadedPlayer()
        #expect(player.duration > 0, "the article never loaded; the test proves nothing")

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
