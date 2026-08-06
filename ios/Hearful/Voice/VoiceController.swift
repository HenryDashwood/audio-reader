import Foundation

@MainActor
protocol SpeechRecognizing {
    /// Listens until she stops speaking, then returns what was heard.
    func listen() async throws -> String
    func cancel()
}

@MainActor
protocol Speaking {
    /// Returns once the sentence has finished being read aloud.
    func speak(_ text: String) async
    func stop()
}

@MainActor
protocol AudioPlaying {
    var isPlaying: Bool { get }
    /// Starts buffering without playing, so the wait overlaps the confirmation.
    func prepare(_ episode: Episode)
    func play(_ episode: Episode) throws
    func pause()
}

enum VoiceState: Equatable {
    case idle
    case listening
    case thinking
    case playing(Episode)
}

/// Owns the whole spoken interaction. Deliberately holds no system frameworks
/// of its own, so every rule below is exercised by tests rather than by ear.
@MainActor
final class VoiceController: ObservableObject {
    @Published private(set) var state: VoiceState = .idle
    @Published private(set) var lastSpokenResponse = ""

    private let api: HearfulAPIProtocol
    private let speech: SpeechRecognizing
    private let speaker: Speaking
    private let player: AudioPlaying
    private let feedback: FeedbackPlaying
    private var isBusy = false

    init(
        api: HearfulAPIProtocol, speech: SpeechRecognizing, speaker: Speaking,
        player: AudioPlaying, feedback: FeedbackPlaying
    ) {
        self.api = api
        self.speech = speech
        self.speaker = speaker
        self.player = player
        self.feedback = feedback
    }

    func beginCommand() async {
        // Taps are easy to double up when you cannot see the screen.
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        // Before anything slow happens: confirm the tap landed.
        feedback.play(.acknowledged)

        // Anything playing would otherwise be transcribed as if she said it.
        if player.isPlaying { player.pause() }

        do {
            state = .listening
            feedback.play(.listening)
            let transcript = try await speech.listen()
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await fail(saying: "I did not hear anything. Tap and try again.")
                return
            }

            state = .thinking
            let response = try await api.command(transcript: transcript)
            await handle(response)
        } catch let error as APIError {
            await fail(saying: error.spokenResponse)
        } catch {
            await fail(saying: "Sorry, I could not hear you. Please tap and try again.")
        }
    }

    private func handle(_ response: CommandResponse) async {
        switch response.action {
        case .unknown:
            await finish(saying: response.spokenResponse)

        case .playEpisode:
            guard let episode = response.episode, episode.audioURL != nil else {
                await fail(saying: "Sorry, I cannot play that one yet.")
                return
            }
            // Buffer while the confirmation is spoken, so the network wait and
            // the sentence happen at the same time rather than back to back.
            player.prepare(episode)
            // Confirm first and wait: overlapping speech and podcast is unusable.
            await say(response.spokenResponse)
            do {
                try player.play(episode)
                state = .playing(episode)
            } catch {
                await fail(saying: "Sorry, that episode would not play.")
            }
        }
    }

    private func say(_ text: String) async {
        lastSpokenResponse = text
        await speaker.speak(text)
    }

    private func finish(saying text: String) async {
        await say(text)
        state = .idle
    }

    private func fail(saying text: String) async {
        feedback.play(.failed)
        await finish(saying: text)
    }
}
