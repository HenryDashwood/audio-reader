import AVFoundation
import Foundation
import Testing

@testable import Hearful

@Suite("Sleep timer phrases")
struct SleepCommandTests {
    @Test(arguments: [
        "set a sleep timer for twenty minutes",
        "stop in twenty minutes",
        "turn off in twenty minutes",
        "go to sleep in 20 minutes",
        "stop playing in 20 minutes",
    ])
    func twentyMinutesIsHeard(_ phrase: String) {
        #expect(SleepCommand.match(phrase) == .after(minutes: 20))
    }

    @Test func halfAnHour() {
        #expect(SleepCommand.match("stop in half an hour") == .after(minutes: 30))
    }

    @Test func anHour() {
        #expect(SleepCommand.match("sleep timer for an hour") == .after(minutes: 60))
    }

    @Test func anHourAndAHalf() {
        #expect(SleepCommand.match("stop in an hour and a half") == .after(minutes: 90))
    }

    @Test func compoundNumbers() {
        #expect(SleepCommand.match("stop in twenty five minutes") == .after(minutes: 25))
    }

    @Test func aBareSleepTimerGetsTheDefault() {
        #expect(SleepCommand.match("set a sleep timer") == .after(minutes: 30))
    }

    @Test(arguments: [
        "cancel the sleep timer",
        "turn off the sleep timer",
        "no sleep timer",
        "forget the sleep timer",
    ])
    func cancellingIsHeard(_ phrase: String) {
        #expect(SleepCommand.match(phrase) == .cancel)
    }

    @Test func aDurationBeatsTheCancelWords() {
        // "turn it off in twenty minutes" is setting a timer, not clearing one.
        #expect(SleepCommand.match("turn it off in twenty minutes") == .after(minutes: 20))
    }

    @Test(arguments: ["pause", "stop", "play", "skip", "go back"])
    func transportCommandsAreNotSleepCommands(_ phrase: String) {
        // A bare "stop" is a pause. Stealing it would mean the most-used
        // control in the app silently set a timer instead.
        #expect(SleepCommand.match(phrase) == nil)
    }

    @Test(arguments: [
        "play the one about sleep",
        "play the sleep episode",
        "subscribe to sleepy history",
        "play the latest episode",
        "play the twenty minute one about sleep",
        "find me something about going to bed",
        "read the article about sleep",
    ])
    func realRequestsAreLeftAlone(_ phrase: String) {
        // Sleep is also a subject people make podcasts about. Hijacking one of
        // these would leave her in silence, having asked to hear something,
        // with no clue why nothing started.
        #expect(SleepCommand.match(phrase) == nil)
    }

    @Test func absurdDurationsAreRejected() {
        // Far more likely a mishearing than a request.
        #expect(SleepCommand.match("stop in 5000 minutes") == nil)
    }
}

@Suite("Sleep timer")
@MainActor
struct SleepTimerTests {
    private func makeTimer(recorder: Recorder) -> (SleepTimer, PlaybackCoordinator) {
        let player = PlaybackCoordinator(
            audio: AudioPlayer(),
            article: ArticlePlayer(api: FakeAPI(), synthesizer: SilentSynthesizer()))
        let timer = SleepTimer(player: player, feedback: FakeFeedback(recorder))
        return (timer, player)
    }

    @Test func startingSetsAnEndTime() {
        let (timer, _) = makeTimer(recorder: Recorder())
        timer.start(minutes: 20)

        #expect(timer.isRunning)
        let remaining = timer.remaining ?? 0
        #expect(remaining > 19 * 60 && remaining <= 20 * 60)
    }

    @Test func cancellingClearsIt() {
        let (timer, _) = makeTimer(recorder: Recorder())
        timer.start(minutes: 20)
        timer.cancel()

        #expect(!timer.isRunning)
        #expect(timer.remaining == nil)
    }

    @Test func startingAgainReplacesTheFirst() {
        let (timer, _) = makeTimer(recorder: Recorder())
        timer.start(minutes: 60)
        timer.start(minutes: 5)

        #expect((timer.remaining ?? 0) <= 5 * 60)
    }

    @Test func firingClearsTheTimer() {
        let (timer, _) = makeTimer(recorder: Recorder())
        timer.start(minutes: 20)
        timer.fire()

        #expect(!timer.isRunning)
    }

    @Test func firingWhileAlreadyPausedMakesNoSound() {
        // She stopped it herself before the timer came round; a chime out of
        // nowhere would be worse than nothing.
        let recorder = Recorder()
        let (timer, _) = makeTimer(recorder: recorder)
        timer.start(minutes: 20)
        timer.fire()

        #expect(!recorder.events.contains(.cue(.finished)))
    }

    enum BufferingPoint: CaseIterable { case startup, midEpisode }

    @Test(arguments: BufferingPoint.allCases)
    func expiryCancelsBufferedPodcastPlayback(at point: BufferingPoint) async throws {
        let file = try silentAudio(seconds: 90)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = AVPlayer()
        let audio = AudioPlayer(defaults: .standard, player: engine, activateAudioSession: {}, progressScope: { nil })
        audio.localFile = { _ in nil }
        let player = PlaybackCoordinator(audio: audio, article: ArticlePlayer())
        let recorder = Recorder()
        let timer = SleepTimer(player: player, feedback: FakeFeedback(recorder))
        let episode = Episode(id: 8721, title: "Podcast", description: nil, audioURL: file,
                              durationSeconds: 90, publishedAt: nil, link: nil)
        defer { player.pause() }
        timer.start(minutes: 30)
        try player.play(episode)
        if point == .midEpisode {
            try await waitFor("Podcast clock to advance") { player.isPlaying && engine.currentTime().seconds > 0.2 }
        }

        // Withhold the item to exercise AVPlayer's waiting state without a network server.
        let item = try #require(engine.currentItem)
        engine.replaceCurrentItem(with: nil)
        try await waitFor("Podcast to enter buffering") { engine.timeControlStatus == .waitingToPlayAtSpecifiedRate && !player.isPlaying }
        timer.fire()
        engine.replaceCurrentItem(with: item)
        try await waitFor("Restored item to become ready") { item.status == .readyToPlay }

        #expect(!timer.isRunning)
        #expect(engine.rate == 0)
        #expect(engine.timeControlStatus == .paused)
        #expect(!player.isPlaying)
        #expect(!recorder.events.contains(.cue(.finished)))

        player.resume()
        try await waitFor("Podcast to resume after Play") { player.isPlaying }
    }

    enum ArticlePreparationStage: CaseIterable { case loadingText, renderingFirstSentence }

    @Test(.serialized, arguments: ArticlePreparationStage.allCases)
    func expiryKeepsArticleAtSavedPassageUntilPlay(during stage: ArticlePreparationStage) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = FakeAPI()
        let passage = "Saved passage begins here."
        let text = String(repeating: "earlier words ", count: 12) + "\n\n" + passage
        api.articleText = text
        let savedChunk = try #require(ArticleScript(text: text).chunks.last)
        let gate = ControlledDelay()
        defer { gate.elapse() }
        let output = NaturalVoiceAudioOutput()
        var rendered: [String] = []
        let synth = NaturalVoiceSynthesizer(
            folder: directory, voice: NaturalVoice(id: "bf_emma"), output: output,
            renderSentence: { sentence, offset in
                if stage == .renderingFirstSentence { try await gate.wait(for: .seconds(30)) }
                rendered.append(sentence)
                // Silent audio with two timed words drives the real output clock and reading marker.
                // Keep the second word playing while a busy simulator schedules assertions.
                let sampleCount = 24_000 * 60
                let audio = NaturalVoiceEngine.Sentence(samples: Array(repeating: 0, count: sampleCount), words: [
                    .init(characters: 0..<5, samples: 0..<12_000),
                    .init(characters: 6..<13, samples: 12_000..<sampleCount),
                ])
                return [(audio, offset)]
            })
        let article = ArticlePlayer(
            api: api, cache: OfflineCache(directory: directory), synthesizer: synth,
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString)),
            progressScope: { nil }, activateAudioSession: {})
        defer { article.clear() }
        if stage == .loadingText {
            // The load reconciles pending progress before fetching the article text.
            article.progressDrain = { try? await gate.wait(for: .seconds(30)) }
        }
        let player = PlaybackCoordinator(audio: AudioPlayer(), article: article)
        let recorder = Recorder()
        let timer = SleepTimer(player: player, feedback: FakeFeedback(recorder))
        timer.start(minutes: 30)
        try player.play(Episode(
            id: 9785, title: "Article", description: nil, audioURL: nil, durationSeconds: nil,
            publishedAt: nil, link: nil, positionSeconds: savedChunk.start, hasText: true))
        try await waitFor("Article preparation to reach the held step") { gate.pendingCount == 1 }
        let marker = article.spokenLocation?.rangeInArticle
        #expect(player.currentTime == savedChunk.start)
        timer.fire()
        gate.elapse()
        await article.waitForPendingLoad()
        if stage == .renderingFirstSentence {
            try await waitFor("First sentence to finish rendering") { rendered == [passage] }
            #expect(synth.isPaused)
        } else {
            #expect(rendered.isEmpty)
        }
        #expect(!timer.isRunning)
        #expect(recorder.events.contains(.cue(.finished)) == (stage == .renderingFirstSentence))
        #expect(!player.isPlaying && !output.isExpectingSound)
        #expect(output.position == 0 && player.currentTime == savedChunk.start)
        #expect(article.spokenLocation?.rangeInArticle == marker)

        player.toggle()
        try await waitFor("Narration to reach the second word after Play") { output.position > 12_000 && player.currentTime > savedChunk.start }
        #expect(player.isPlaying)
        #expect(rendered == [passage])
        #expect(article.spokenLocation?.rangeInArticle.location == savedChunk.textRange.location + 6)
    }

    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "\(description)")
    }

    @Test func durationsAreSpokenAsWords() {
        #expect(SleepTimer.spokenDuration(minutes: 30) == "half an hour")
        #expect(SleepTimer.spokenDuration(minutes: 60) == "an hour")
        #expect(SleepTimer.spokenDuration(minutes: 20) == "20 minutes")
    }
}
