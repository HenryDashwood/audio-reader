import Foundation
import Testing

@testable import Hearful

// MARK: - Fakes

enum Event: Equatable {
    case paused
    case resumed
    case skipped(TimeInterval)
    case spoke(String)
    case prepared(Int)
    case played(Int)
    case cue(Cue)
    case rateSet(Float)
}

@MainActor
final class Recorder {
    var events: [Event] = []
    var spoken: [String] { events.compactMap { if case .spoke(let t) = $0 { t } else { nil } } }
    var playedIDs: [Int] { events.compactMap { if case .played(let id) = $0 { id } else { nil } } }
}

@MainActor
final class FakeSpeech: SpeechRecognizing {
    var transcript = "play something"
    var error: Error?
    var listenCount = 0
    var cancelCount = 0
    /// Keeps the microphone open instead of answering, as it is while she is
    /// still deciding what to say — the state the sheet gets closed in.
    var keepsListening = false
    /// How the wait ends when cancelled. The analyser hands back what it has,
    /// which is nothing; the older recogniser fails instead. Both reach the
    /// controller, so both are worth testing.
    var failsWhenCancelled = false
    private var pending: CheckedContinuation<String, Error>?

    /// Whether the microphone is open right now, so a test can close the sheet
    /// at that moment rather than at whichever one the scheduler reached.
    var isListening: Bool { pending != nil }

    func listen(onReady: @MainActor () -> Void) async throws -> String {
        listenCount += 1
        if let error { throw error }
        onReady()
        guard keepsListening else { return transcript }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        guard let pending else { return }
        self.pending = nil
        if failsWhenCancelled {
            pending.resume(throwing: URLError(.cancelled))
        } else {
            pending.resume(returning: "")
        }
    }
}

@MainActor
final class FakeSpeaker: Speaking {
    let recorder: Recorder
    /// Holds the sentence open until `stop`, as a real utterance does — long
    /// enough for the sheet to be closed part-way through it.
    var keepsSpeaking = false
    private var pending: CheckedContinuation<Void, Never>?

    init(_ recorder: Recorder) { self.recorder = recorder }

    func speak(_ text: String) async {
        recorder.events.append(.spoke(text))
        guard keepsSpeaking else { return }
        await withCheckedContinuation { self.pending = $0 }
    }

    func stop() {
        let pending = self.pending
        self.pending = nil
        pending?.resume()
    }
}

@MainActor
final class FakePlayer: AudioPlaying {
    let recorder: Recorder
    var isPlaying = false
    var currentEpisode: Episode?
    var failure: Error?
    init(_ recorder: Recorder) { self.recorder = recorder }

    func prepare(_ episode: Episode) {
        recorder.events.append(.prepared(episode.id))
    }
    func play(_ episode: Episode) throws {
        if let failure { throw failure }
        recorder.events.append(.played(episode.id))
        currentEpisode = episode
        isPlaying = true
    }
    func pause() {
        recorder.events.append(.paused)
        isPlaying = false
    }
    func resume() {
        recorder.events.append(.resumed)
        isPlaying = true
    }
    func skip(by seconds: TimeInterval) {
        recorder.events.append(.skipped(seconds))
    }

    var playbackRate: Float = 1.0
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        recorder.events.append(.rateSet(rate))
    }
}

@MainActor
final class FakeFeedback: FeedbackPlaying {
    let recorder: Recorder
    init(_ recorder: Recorder) { self.recorder = recorder }
    func play(_ cue: Cue) { recorder.events.append(.cue(cue)) }
}

final class FakeAPI: HearfulAPIProtocol, @unchecked Sendable {
    var response: CommandResponse?
    var error: Error?
    var transcripts: [String] = []
    /// How long the backend takes to answer.
    var delay: Duration = .zero

    /// What the phone said was playing, per request.
    var nowPlayingIDs: [Int?] = []

    func command(transcript: String, nowPlayingEpisodeID: Int? = nil, traceparent: String? = nil) async throws
        -> CommandResponse {
        transcripts.append(transcript)
        nowPlayingIDs.append(nowPlayingEpisodeID)
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let error { throw error }
        return response ?? CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)
    }

    func recentEpisodes(limit: Int) async throws -> [Episode] {
        Array(episodesByID.values)
    }

    var shows: [Show] = []
    /// Set to make the library request fail, for the offline-cache tests.
    var showsError: Error?
    func shows() async throws -> [Show] {
        if let showsError { throw showsError }
        return shows
    }
    var episodesError: Error?
    func episodes(showID: Int) async throws -> [Episode] {
        if let episodesError { throw episodesError }
        return Array(episodesByID.values)
    }

    var episodesByID: [Int: Episode] = [:]
    func episode(id: Int) async throws -> Episode {
        guard let found = episodesByID[id] else {
            throw APIError(underlying: "no such episode")
        }
        return found
    }

    func login(appleIdentityToken: String, authorizationCode: String?) async throws
        -> AuthResponse
    {
        AuthResponse(token: "fake-token", user: UserInfo(id: "u1", displayName: nil))
    }
    func logout() async throws {}
    func deleteAccount() async throws {}
    func me() async throws -> UserInfo { UserInfo(id: "u1", displayName: nil) }

    var reportedPositions: [(episodeID: Int, seconds: Double, completed: Bool)] = []
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws {
        reportedPositions.append((episodeID, seconds, completed))
    }

    var filings: [(episodeID: Int, played: Bool?, dismissed: Bool?)] = []
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws {
        filings.append((episodeID, played, dismissed))
    }

    var reportedAttempts: [[String: any Sendable]] = []
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String? = nil) async throws {
        reportedAttempts.append(event)
    }

    func reportDiagnostic(_ event: [String: any Sendable]) async throws {}

    /// Set to let the article player actually load and speak something.
    var articleText: String?
    func articleText(episodeID: Int) async throws -> EpisodeText {
        guard let articleText else { throw APIError(underlying: "unused") }
        return EpisodeText(episodeID: episodeID, title: "An article", text: articleText)
    }
    func searchPodcasts(query: String) async throws -> [PodcastResult] { [] }
    func previewFeed(url: URL) async throws -> FeedPreview { throw APIError(underlying: "unused") }
    func subscribe(feedURL: URL) async throws -> Show { throw APIError(underlying: "unused") }
    func unsubscribe(showID: Int) async throws {}
}

// MARK: - Fixtures

private func episode(id: Int = 104, audio: String? = "https://cdn.example.com/104.mp3") -> Episode {
    Episode(
        id: id, title: "The Congress of Vienna", description: nil,
        audioURL: audio.flatMap(URL.init(string:)), durationSeconds: 2700,
        publishedAt: nil, link: nil)
}

@MainActor
private func makeController(
    speech: FakeSpeech? = nil,
    api: FakeAPI = FakeAPI(),
    holdsTheConfirmation: Bool = false
) -> (VoiceController, Recorder, FakeSpeech, FakeAPI, FakePlayer) {
    let recorder = Recorder()
    let speech = speech ?? FakeSpeech()
    let player = FakePlayer(recorder)
    let speaker = FakeSpeaker(recorder)
    speaker.keepsSpeaking = holdsTheConfirmation
    // Its own sleep timer, not the shared one: tests run in parallel and must
    // not set timers on each other's behalf.
    let sleepTimer = SleepTimer(
        player: PlaybackCoordinator(audio: AudioPlayer(), article: ArticlePlayer(api: api)),
        feedback: FakeFeedback(recorder))
    let controller = VoiceController(
        api: api, speech: speech, speaker: speaker, player: player,
        feedback: FakeFeedback(recorder), sleepTimer: sleepTimer)
    return (controller, recorder, speech, api, player)
}

/// Runs the command far enough for the moment under test to have arrived.
/// Bounded rather than a bare loop: a condition that never comes true should
/// fail the expectation below it, not hang the suite.
@MainActor
private func wait(until condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        await Task.yield()
    }
}

// MARK: - Tests

@Suite("Voice controller")
@MainActor
struct VoiceControllerTests {
    @Test func playsTheEpisodeTheBackendChose() async {
        let (controller, recorder, _, api, _) = makeController()
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode())

        await controller.beginCommand()

        #expect(recorder.playedIDs == [104])
        #expect(controller.state == .playing(episode()))
    }

    @Test func confirmsAloudBeforePlaying() async {
        // If the confirmation and the podcast overlap she hears neither.
        let (controller, recorder, _, api, _) = makeController()
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode())

        await controller.beginCommand()

        let meaningful = recorder.events.filter {
            if case .cue = $0 { return false } else { return true }
        }
        #expect(meaningful == [.prepared(104), .spoke("Playing it."), .played(104)])
    }

    @Test func buffersTheEpisodeWhileTheConfirmationIsSpoken() async {
        // Loading only after the confirmation would add its own delay on top;
        // buffering during the sentence hides it entirely.
        let (controller, recorder, _, api, _) = makeController()
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode())

        await controller.beginCommand()

        let preparedAt = recorder.events.firstIndex(of: .prepared(104))
        let spokeAt = recorder.events.firstIndex(of: .spoke("Playing it."))
        #expect(preparedAt != nil && spokeAt != nil && preparedAt! < spokeAt!)
    }

    @Test func acknowledgesTheTapImmediately() async {
        // She cannot see the icon change, so silence between tapping and
        // listening reads as "it did not hear me".
        let (controller, recorder, _, _, _) = makeController()
        await controller.beginCommand()

        #expect(recorder.events.first == .cue(.acknowledged))
    }

    @Test func signalsWhenItStartsListening() async {
        let (controller, recorder, _, _, _) = makeController()
        await controller.beginCommand()

        #expect(recorder.events.contains(.cue(.listening)))
    }

    @Test func theGoAheadWaitsForTheMicrophone() async {
        // Told to speak before the mic is capturing, her first words are lost —
        // and setting up can mean a permission prompt or a model download.
        let speech = FakeSpeech()
        speech.error = URLError(.cancelled)  // never reaches capture
        let (controller, recorder, _, _, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(!recorder.events.contains(.cue(.listening)))
    }

    @Test func fasterNudgesTheRateLocally() async {
        let speech = FakeSpeech()
        speech.transcript = "faster"
        let (controller, recorder, _, api, player) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(recorder.events.contains(.rateSet(1.25)))
        #expect(player.playbackRate == 1.25)
        #expect(api.transcripts.isEmpty)  // never left the phone
    }

    @Test func fasterStopsAtTheCeiling() async {
        let speech = FakeSpeech()
        speech.transcript = "faster"
        let (controller, _, _, _, player) = makeController(speech: speech)
        player.playbackRate = 2.0

        await controller.beginCommand()

        #expect(player.playbackRate == 2.0)
    }

    @Test func normalSpeedResetsTheRate() async {
        let speech = FakeSpeech()
        speech.transcript = "normal speed"
        let (controller, _, _, _, player) = makeController(speech: speech)
        player.playbackRate = 1.75

        await controller.beginCommand()

        #expect(player.playbackRate == 1.0)
    }

    @Test func backendSetSpeedIsAppliedAndConfirmed() async {
        // "play at one and a half speed" is not a local phrase; the model
        // resolves it and the app applies the multiplier it sends back.
        let speech = FakeSpeech()
        speech.transcript = "play at one and a half speed"
        let (controller, recorder, _, api, player) = makeController(speech: speech)
        api.response = CommandResponse(
            action: .setSpeed, spokenResponse: "1.5 times speed.", episode: nil, speed: 1.5)

        await controller.beginCommand()

        #expect(player.playbackRate == 1.5)
        #expect(recorder.spoken == ["1.5 times speed."])
    }

    @Test func pausesPlaybackBeforeListening() async {
        // The recogniser would otherwise hear the podcast, not her.
        let (controller, recorder, _, api, player) = makeController()
        player.isPlaying = true
        api.response = CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)

        await controller.beginCommand()

        #expect(recorder.events.contains(.paused))
    }

    @Test func doesNotPauseWhenNothingIsPlaying() async {
        let (controller, recorder, _, _, _) = makeController()
        await controller.beginCommand()
        #expect(!recorder.events.contains(.paused))
    }

    @Test func sendsTheTranscriptToTheBackend() async {
        let speech = FakeSpeech()
        speech.transcript = "play the one about the aliens lady"
        let (controller, _, _, api, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(api.transcripts == ["play the one about the aliens lady"])
    }

    @Test func unknownActionSpeaksTheClarificationAndPlaysNothing() async {
        let (controller, recorder, _, api, _) = makeController()
        api.response = CommandResponse(
            action: .unknown, spokenResponse: "Which show would you like?", episode: nil)

        await controller.beginCommand()

        #expect(recorder.spoken == ["Which show would you like?"])
        #expect(recorder.playedIDs.isEmpty)
        #expect(controller.state == .idle)
    }

    @Test func blankTranscriptNeverReachesTheBackend() async {
        let speech = FakeSpeech()
        speech.transcript = "   "
        let (controller, recorder, _, api, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(api.transcripts.isEmpty)
        #expect(!recorder.spoken.isEmpty)  // still says something
        #expect(controller.state == .idle)
    }

    @Test func episodeWithNeitherAudioNorTextIsNotPlayed() async {
        // Acting on something unplayable would fail silently.
        let (controller, recorder, _, api, _) = makeController()
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode(audio: nil))

        await controller.beginCommand()

        #expect(recorder.playedIDs.isEmpty)
        #expect(controller.state == .idle)
    }

    @Test func saysOneMomentWhileASlowAnswerIsFetched() async {
        // An unexplained silence is indistinguishable from being ignored.
        let (controller, recorder, _, api, _) = makeController()
        // Two seconds clear of the notice threshold, not four hundred
        // milliseconds. The margin has to absorb a loaded machine: on busy
        // shared hardware the notice's sleep overshoots, the answer arrives
        // first, and the filler is correctly suppressed — a real pass that
        // reads as a failure. What is being tested is that a slow answer
        // gets a holding line, and a wider gap tests that just as well.
        api.delay = VoiceController.noticeAfter + .milliseconds(2000)
        api.response = CommandResponse(
            action: .unknown, spokenResponse: "Which show?", episode: nil)

        await controller.beginCommand()

        #expect(recorder.spoken == ["One moment.", "Which show?"])
    }

    @Test func aPromptAnswerIsNotDelayedByFiller() async {
        let (controller, recorder, _, api, _) = makeController()
        api.response = CommandResponse(
            action: .unknown, spokenResponse: "Which show?", episode: nil)

        await controller.beginCommand()

        #expect(recorder.spoken == ["Which show?"])
    }

    @Test func theHoldingLineIsNotLeftAsTheCaption() async {
        // It answers "is it still there?", not "what did you ask for?" — the
        // idle screen should show her the real reply.
        let (controller, _, _, api, _) = makeController()
        api.delay = VoiceController.noticeAfter + .milliseconds(400)
        api.response = CommandResponse(
            action: .unknown, spokenResponse: "Which show?", episode: nil)

        await controller.beginCommand()

        #expect(controller.lastSpokenResponse == "Which show?")
    }

    @Test func articleWithTextIsPlayed() async {
        // No audio URL, but the backend can supply text: the player reads it.
        let (controller, recorder, _, api, _) = makeController()
        var article = episode(audio: nil)
        article.hasText = true
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Reading it.", episode: article)

        await controller.beginCommand()

        #expect(recorder.playedIDs == [104])
        #expect(controller.state == .playing(article))
    }
}

@Suite("Transport commands never reach the network")
@MainActor
struct VoiceControllerTransportTests {
    @Test func pauseIsHandledOnTheDevice() async {
        let speech = FakeSpeech()
        speech.transcript = "pause"
        let (controller, recorder, _, api, player) = makeController(speech: speech)
        player.isPlaying = true

        await controller.beginCommand()

        #expect(api.transcripts.isEmpty)  // no round trip
        #expect(recorder.events.contains(.paused))
        #expect(recorder.spoken.isEmpty)  // the silence is the confirmation
    }

    @Test func resumeIsHandledOnTheDevice() async {
        let speech = FakeSpeech()
        speech.transcript = "carry on"
        let (controller, recorder, _, api, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(api.transcripts.isEmpty)
        #expect(recorder.events.contains(.resumed))
    }

    @Test func skippingMovesForwardAndBack() async {
        let forward = FakeSpeech()
        forward.transcript = "skip forward"
        let (a, recorderA, _, _, _) = makeController(speech: forward)
        await a.beginCommand()

        let back = FakeSpeech()
        back.transcript = "go back"
        let (b, recorderB, _, _, _) = makeController(speech: back)
        await b.beginCommand()

        #expect(recorderA.events.contains { if case .skipped(let s) = $0 { s > 0 } else { false } })
        #expect(recorderB.events.contains { if case .skipped(let s) = $0 { s < 0 } else { false } })
    }

    @Test func aRealRequestStillGoesToTheBackend() async {
        let speech = FakeSpeech()
        speech.transcript = "play the one about the aliens lady"
        let (controller, _, _, api, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(api.transcripts == ["play the one about the aliens lady"])
    }

    @Test func pausingDoesNotLeaveTheAppLookingBusy() async {
        let speech = FakeSpeech()
        speech.transcript = "pause"
        let (controller, _, _, _, player) = makeController(speech: speech)
        player.isPlaying = true

        await controller.beginCommand()

        #expect(controller.state == .idle)
    }
}

@Suite("Playback survives an interruption")
@MainActor
struct VoiceControllerResumeTests {
    @Test func whatWasPlayingCarriesOnAfterAnUnrecognisedRequest() async {
        // Otherwise a misheard word silently ends her episode, and she has to
        // work out that it stopped and ask for it again.
        let (controller, recorder, _, api, player) = makeController()
        player.isPlaying = true
        api.response = CommandResponse(
            action: .unknown, spokenResponse: "Which show?", episode: nil)

        await controller.beginCommand()

        #expect(recorder.events.contains(.resumed))
    }

    @Test func carriesOnAfterAFailedRequestToo() async {
        let (controller, recorder, _, api, player) = makeController()
        player.isPlaying = true
        api.error = APIError(spokenResponse: "I cannot reach the internet.", underlying: "offline")

        await controller.beginCommand()

        #expect(recorder.events.contains(.resumed))
    }

    @Test func aNewEpisodeReplacesTheOldOneRatherThanResumingIt() async {
        let (controller, recorder, _, api, player) = makeController()
        player.isPlaying = true
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode())

        await controller.beginCommand()

        #expect(!recorder.events.contains(.resumed))
        #expect(recorder.playedIDs == [104])
    }

    @Test func sayingPauseLeavesItPaused() async {
        // She asked for silence; resuming would be maddening.
        let speech = FakeSpeech()
        speech.transcript = "pause"
        let (controller, recorder, _, _, player) = makeController(speech: speech)
        player.isPlaying = true

        await controller.beginCommand()

        #expect(!recorder.events.contains(.resumed))
        #expect(recorder.events.contains(.paused))
    }

    @Test func nothingStartsPlayingIfNothingWasPlaying() async {
        let (controller, recorder, _, api, _) = makeController()
        api.response = CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)

        await controller.beginCommand()

        #expect(!recorder.events.contains(.resumed))
    }
}

@Suite("Voice controller failures")
@MainActor
struct VoiceControllerFailureTests {
    @Test func apiErrorIsSpokenAloud() async {
        let (controller, recorder, _, api, _) = makeController()
        api.error = APIError(spokenResponse: "I cannot reach the internet.", underlying: "offline")

        await controller.beginCommand()

        #expect(recorder.spoken == ["I cannot reach the internet."])
        #expect(controller.state == .idle)
    }

    @Test func speechFailureIsSpokenAloud() async {
        let speech = FakeSpeech()
        speech.error = URLError(.cancelled)
        let (controller, recorder, _, _, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(!recorder.spoken.isEmpty)
        #expect(controller.state == .idle)
    }

    @Test func playbackFailureIsSpokenAloud() async {
        let (controller, recorder, _, api, player) = makeController()
        player.failure = URLError(.cannotOpenFile)
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode())

        await controller.beginCommand()

        #expect(recorder.spoken.count == 2)  // confirmation, then the apology
        #expect(controller.state == .idle)
    }

    @Test func aSecondTapWhileBusyIsIgnored() async {
        // Double taps are easy to make when you cannot see the screen.
        let (controller, _, speech, _, _) = makeController()
        async let first: Void = controller.beginCommand()
        async let second: Void = controller.beginCommand()
        _ = await (first, second)

        #expect(speech.listenCount == 1)
    }

    // MARK: - Sleep timer

    @Test func aSleepRequestNeverReachesTheNetwork() async {
        let speech = FakeSpeech()
        speech.transcript = "stop in twenty minutes"
        let (controller, _, _, api, _) = makeController(speech: speech)

        await controller.beginCommand()

        // Setting a timer at bedtime must not depend on having signal.
        #expect(api.transcripts.isEmpty)
    }

    @Test func aSleepRequestIsConfirmedAloud() async {
        // Unlike pause or skip there is no audible change to hear, and she is
        // about to stop paying attention.
        let speech = FakeSpeech()
        speech.transcript = "stop in twenty minutes"
        let (controller, recorder, _, _, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(recorder.spoken == ["I will stop in 20 minutes."])
    }

    @Test func cancellingTheTimerIsConfirmedAloud() async {
        let speech = FakeSpeech()
        speech.transcript = "cancel the sleep timer"
        let (controller, recorder, _, _, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(recorder.spoken == ["Sleep timer off."])
    }

    @Test func settingATimerLeavesTheEpisodePlaying() async {
        // She interrupted it to speak; it must come back.
        let speech = FakeSpeech()
        speech.transcript = "stop in twenty minutes"
        let (controller, recorder, _, _, player) = makeController(speech: speech)
        player.isPlaying = true

        await controller.beginCommand()

        #expect(recorder.events.contains(.resumed))
    }

    @Test func aBarePauseIsStillAPause() async {
        // The sleep matcher runs first; it must not swallow "stop".
        let speech = FakeSpeech()
        speech.transcript = "stop"
        let (controller, recorder, _, _, player) = makeController(speech: speech)
        player.isPlaying = true

        await controller.beginCommand()

        #expect(recorder.events.contains(.paused))
        #expect(!recorder.events.contains(.resumed))
    }

    // MARK: - Permission

    @Test func deniedPermissionIsExplained() async {
        let speech = FakeSpeech()
        speech.error = SpeechPermissionDenied()
        let (controller, recorder, _, _, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(recorder.spoken == [VoiceController.permissionMessage])
    }

    @Test func deniedPermissionSaysWhereToFixIt() async {
        // The generic apology sends her to tap again, which can never work.
        let speech = FakeSpeech()
        speech.error = SpeechPermissionDenied()
        let (controller, recorder, _, _, _) = makeController(speech: speech)

        await controller.beginCommand()

        let said = recorder.spoken.joined()
        #expect(said.contains("Settings"))
        #expect(!said.contains("try again"))
    }

    @Test func deniedPermissionRaisesTheFlagForTheSettingsButton() async {
        let speech = FakeSpeech()
        speech.error = SpeechPermissionDenied()
        let (controller, _, _, _, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(controller.needsPermission)
    }

    @Test func grantingPermissionClearsTheFlag() async {
        let speech = FakeSpeech()
        speech.error = SpeechPermissionDenied()
        let (controller, _, _, api, _) = makeController(speech: speech)
        await controller.beginCommand()
        #expect(controller.needsPermission)

        // She has been to Settings and come back.
        speech.error = nil
        api.response = CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)
        await controller.beginCommand()

        #expect(!controller.needsPermission)
    }

    @Test func anOrdinaryFailureIsNotTreatedAsAPermissionProblem() async {
        let speech = FakeSpeech()
        speech.error = URLError(.timedOut)
        let (controller, recorder, _, _, _) = makeController(speech: speech)

        await controller.beginCommand()

        #expect(!controller.needsPermission)
        #expect(recorder.spoken == ["Sorry, I could not hear you. Please tap and try again."])
    }

    @Test func deniedPermissionStillPutsBackWhatWasPlaying() async {
        // Being refused the microphone must not also cost her the episode.
        let speech = FakeSpeech()
        speech.error = SpeechPermissionDenied()
        let (controller, recorder, _, _, player) = makeController(speech: speech)
        player.isPlaying = true

        await controller.beginCommand()

        #expect(recorder.events.contains(.resumed))
    }
}

/// Closing the sheet is a change of mind, and nothing downstream of it stops
/// on its own. Left running, the recogniser waits out its silence timer and
/// the app then announces "I did not hear anything" — seconds late, to a sheet
/// that has gone, over whatever she is doing by then.
@Suite("Closing the sheet ends the command")
@MainActor
struct VoiceControllerCancelTests {
    /// The command, left listening at the point where she closes the sheet.
    private func listening(
        player isPlaying: Bool = false, failsWhenCancelled: Bool = false
    ) async -> (VoiceController, Recorder, FakeSpeech) {
        let speech = FakeSpeech()
        speech.keepsListening = true
        speech.failsWhenCancelled = failsWhenCancelled
        let (controller, recorder, _, _, player) = makeController(speech: speech)
        player.isPlaying = isPlaying
        Task { await controller.beginCommand() }
        await wait { speech.isListening }
        // Asserted, not assumed: every test below is about what happens when
        // the sheet closes mid-listen, and one that never got there would
        // otherwise pass by having nothing to go wrong.
        #expect(speech.isListening)
        return (controller, recorder, speech)
    }

    @Test func theMicrophoneIsToldToStop() async {
        let (controller, _, speech) = await listening()

        controller.cancel()

        #expect(speech.cancelCount == 1)
    }

    @Test func nothingIsSaidAfterwards() async {
        // The whole point: the analyser answers cancellation by handing back
        // what it has, which is nothing — the exact input that produces "I did
        // not hear anything".
        let (controller, recorder, _) = await listening()

        controller.cancel()
        await wait { controller.state == .idle }

        #expect(recorder.spoken.isEmpty)
    }

    @Test func nothingIsSaidWhenTheRecogniserFailsInstead() async {
        // The older recogniser ends the wait by throwing rather than
        // returning, and that arrives in a different branch of the controller.
        let (controller, recorder, _) = await listening(failsWhenCancelled: true)

        controller.cancel()
        await wait { controller.state == .idle }

        #expect(recorder.spoken.isEmpty)
    }

    @Test func noFailureCueIsPlayed() async {
        // A sound is as much of an answer as a sentence, and she cannot see
        // that the sheet closed to explain it.
        let (controller, recorder, _) = await listening()

        controller.cancel()
        await wait { controller.state == .idle }

        #expect(!recorder.events.contains(.cue(.failed)))
    }

    @Test func itGoesBackToIdle() async {
        let (controller, _, _) = await listening()

        controller.cancel()

        #expect(controller.state == .idle)
    }

    @Test func whatWasPlayingCarriesOn() async {
        // She interrupted an episode to speak and then thought better of it;
        // changing her mind must not cost her the episode.
        let (controller, recorder, _) = await listening(player: true)

        controller.cancel()
        await wait { recorder.events.contains(.resumed) }

        #expect(recorder.events.contains(.resumed))
    }

    @Test func aLateAnswerFromTheBackendIsNotActedOn() async {
        // Closing the sheet while it is thinking is still a change of mind:
        // an episode starting a second later would be answering a withdrawn
        // question, with no visible cause and nothing on screen to stop it.
        let (controller, recorder, _, api, _) = makeController()
        api.delay = .milliseconds(50)
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode())

        Task { await controller.beginCommand() }
        await wait { controller.state == .thinking }
        #expect(controller.state == .thinking)
        controller.cancel()
        await wait { api.transcripts.count == 1 }
        // Comfortably past the answer, which the controller must now ignore.
        try? await Task.sleep(for: .milliseconds(200))

        #expect(recorder.playedIDs.isEmpty)
        #expect(recorder.spoken.isEmpty)
    }

    @Test func closingDuringTheConfirmationDoesNotStartTheEpisode() async {
        let speech = FakeSpeech()
        let (controller, recorder, _, api, player) = makeController(
            speech: speech, holdsTheConfirmation: true)
        player.isPlaying = true
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode())

        Task { await controller.beginCommand() }
        await wait { recorder.events.contains(.spoke("Playing it.")) }
        #expect(recorder.events.contains(.spoke("Playing it.")))
        controller.cancel()
        await wait { recorder.events.contains(.resumed) }

        #expect(recorder.playedIDs.isEmpty)
        #expect(recorder.events.contains(.resumed))  // the old episode is back
    }

    @Test func closingAfterSomethingStartedPlayingLeavesItPlaying() async {
        // The sheet closes itself the moment playback begins, so this path is
        // reached on every successful command. It must not undo the command it
        // is the confirmation of.
        let (controller, recorder, _, api, _) = makeController()
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode())
        await controller.beginCommand()

        controller.cancel()

        #expect(controller.state == .playing(episode()))
        #expect(!recorder.events.contains(.paused))
    }

    @Test func cancellingWhenNothingIsHappeningDoesNothing() async {
        let (controller, recorder, speech, _, _) = makeController()

        controller.cancel()

        #expect(speech.cancelCount == 0)
        #expect(recorder.events.isEmpty)
    }
}

@Suite("Filing episodes by voice")
@MainActor
struct VoiceFilingTests {
    private func filingResponse(_ action: CommandAction, _ episode: Episode) -> CommandResponse {
        CommandResponse(action: action, spokenResponse: "Marked as played: it.", episode: episode)
    }

    @Test func tellsTheBackendWhatIsPlaying() async {
        // "Mark this as played" has no referent otherwise: the backend knows
        // her whole library and nothing about which part of it she can hear.
        let (controller, _, _, api, player) = makeController()
        player.currentEpisode = episode()

        await controller.beginCommand()

        #expect(api.nowPlayingIDs == [104])
    }

    @Test func sendsNoEpisodeWhenNothingIsPlaying() async {
        let (controller, _, _, api, _) = makeController()

        await controller.beginCommand()

        #expect(api.nowPlayingIDs == [nil])
    }

    @Test func stopsTheEpisodeItJustTookOffTheList() async {
        // Answering "I have already heard this" by playing more of it is the
        // obvious wrong behaviour; the quiet one is that carrying on lets the
        // position reporter write the episode's state back over hers.
        let (controller, recorder, _, api, player) = makeController()
        player.currentEpisode = episode()
        player.isPlaying = true
        api.response = filingResponse(.markPlayed, episode())

        await controller.beginCommand()

        #expect(recorder.events.contains(.paused))
        #expect(!recorder.events.contains(.resumed))
    }

    @Test func leavesADifferentEpisodePlaying() async {
        // Filing something from her list while listening to something else
        // must not interrupt what she is listening to.
        let (controller, recorder, _, api, player) = makeController()
        player.currentEpisode = episode(id: 104)
        player.isPlaying = true
        api.response = filingResponse(.markPlayed, episode(id: 999))

        await controller.beginCommand()

        #expect(recorder.events.contains(.resumed))
    }

    @Test func restoringDoesNotStopAnything() async {
        // Putting an episode back is not a reason to stop playing it.
        let (controller, recorder, _, api, player) = makeController()
        player.currentEpisode = episode()
        player.isPlaying = true
        api.response = CommandResponse(
            action: .restore, spokenResponse: "Back in your list: it.", episode: episode())

        await controller.beginCommand()

        #expect(recorder.events.contains(.resumed))
    }

    @Test func saysWhatHappened() async {
        // The only evidence there is: a row leaving a list she cannot see.
        let (controller, recorder, _, api, _) = makeController()
        api.response = filingResponse(.dismiss, episode())

        await controller.beginCommand()

        #expect(recorder.spoken.contains("Marked as played: it."))
    }

    @Test func aFilingWithNoEpisodeIsJustSpoken() async {
        // The backend asking which one she meant, or an older app meeting a
        // newer backend: say the sentence, touch nothing.
        let (controller, recorder, _, api, player) = makeController()
        player.currentEpisode = episode()
        player.isPlaying = true
        api.response = CommandResponse(
            action: .markPlayed, spokenResponse: "Which episode?", episode: nil)

        await controller.beginCommand()

        #expect(recorder.spoken.contains("Which episode?"))
        #expect(recorder.events.contains(.resumed))
    }
}
