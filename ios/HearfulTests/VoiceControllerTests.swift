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

    func listen() async throws -> String {
        listenCount += 1
        if let error { throw error }
        return transcript
    }
    func cancel() {}
}

@MainActor
final class FakeSpeaker: Speaking {
    let recorder: Recorder
    init(_ recorder: Recorder) { self.recorder = recorder }
    func speak(_ text: String) async { recorder.events.append(.spoke(text)) }
    func stop() {}
}

@MainActor
final class FakePlayer: AudioPlaying {
    let recorder: Recorder
    var isPlaying = false
    var failure: Error?
    init(_ recorder: Recorder) { self.recorder = recorder }

    func prepare(_ episode: Episode) {
        recorder.events.append(.prepared(episode.id))
    }
    func play(_ episode: Episode) throws {
        if let failure { throw failure }
        recorder.events.append(.played(episode.id))
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

    func command(transcript: String) async throws -> CommandResponse {
        transcripts.append(transcript)
        if let error { throw error }
        return response ?? CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)
    }

    func recentEpisodes(limit: Int) async throws -> [Episode] {
        Array(episodesByID.values)
    }

    var episodesByID: [Int: Episode] = [:]
    func episode(id: Int) async throws -> Episode {
        guard let found = episodesByID[id] else {
            throw APIError(underlying: "no such episode")
        }
        return found
    }
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
    api: FakeAPI = FakeAPI()
) -> (VoiceController, Recorder, FakeSpeech, FakeAPI, FakePlayer) {
    let recorder = Recorder()
    let speech = speech ?? FakeSpeech()
    let player = FakePlayer(recorder)
    let controller = VoiceController(
        api: api, speech: speech, speaker: FakeSpeaker(recorder), player: player,
        feedback: FakeFeedback(recorder))
    return (controller, recorder, speech, api, player)
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

    @Test func episodeWithoutAudioIsNotPlayed() async {
        // Articles have no audio yet; acting on one would fail silently.
        let (controller, recorder, _, api, _) = makeController()
        api.response = CommandResponse(
            action: .playEpisode, spokenResponse: "Playing it.", episode: episode(audio: nil))

        await controller.beginCommand()

        #expect(recorder.playedIDs.isEmpty)
        #expect(controller.state == .idle)
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
}
