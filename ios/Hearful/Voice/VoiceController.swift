import Foundation

@MainActor
protocol SpeechRecognizing {
    /// Listens until she stops speaking, then returns what was heard.
    ///
    /// `onReady` fires when the microphone is actually capturing. What comes
    /// before it — permission, a model download, starting the engine — can
    /// take seconds, and anything said during that is simply lost, so the
    /// go-ahead she hears must wait for this rather than for the tap.
    func listen(onReady: @MainActor () -> Void) async throws -> String
    func cancel()
}

extension SpeechRecognizing {
    func listen() async throws -> String { try await listen(onReady: {}) }
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
    var playbackRate: Float { get }
    /// Starts buffering without playing, so the wait overlaps the confirmation.
    func prepare(_ episode: Episode)
    func play(_ episode: Episode) throws
    func pause()
    func resume()
    func skip(by seconds: TimeInterval)
    func setPlaybackRate(_ rate: Float)
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
    /// How long a wait may go unexplained. Long enough that a prompt answer
    /// arrives on its own, short enough that the silence never feels broken.
    static let noticeAfter = Duration.milliseconds(600)

    /// What she is told when listening is not permitted. Long, unlike every
    /// other spoken line here, because it is the only one that has to carry
    /// instructions she cannot read off the screen.
    static let permissionMessage = """
        Hearful needs permission to listen. Open the Settings app, choose \
        Hearful, and turn on Microphone and Speech Recognition.
        """

    @Published private(set) var state: VoiceState = .idle
    @Published private(set) var lastSpokenResponse = ""
    /// True once listening has been refused for want of permission. The sheet
    /// puts a button on screen so the trip to Settings is one tap rather than
    /// a hunt through someone else's app.
    @Published private(set) var needsPermission = false

    private let api: HearfulAPIProtocol
    private let speech: SpeechRecognizing
    private let speaker: Speaking
    private let player: AudioPlaying
    private let feedback: FeedbackPlaying
    private let sleepTimer: SleepTimer
    private let telemetry: TelemetryReporting?
    private var isBusy = false
    /// True while an episode has been paused only so she could be heard.
    private var interruptedPlayback = false

    init(
        api: HearfulAPIProtocol, speech: SpeechRecognizing, speaker: Speaking,
        player: AudioPlaying, feedback: FeedbackPlaying, sleepTimer: SleepTimer = .shared,
        telemetry: TelemetryReporting? = nil
    ) {
        self.api = api
        self.speech = speech
        self.speaker = speaker
        self.player = player
        self.feedback = feedback
        self.sleepTimer = sleepTimer
        self.telemetry = telemetry
    }

    func beginCommand() async {
        // Taps are easy to double up when you cannot see the screen.
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        // One wide event per spoken request, opened here and sent once at the
        // end however it ends — including the ends that never reach the
        // backend, which were invisible until this existed.
        let attempt = VoiceAttempt()
        VoiceAttempt.current = attempt
        defer {
            VoiceAttempt.current = nil
            telemetry?.report(attempt)
        }

        // Before anything slow happens: confirm we are on it — whether she got
        // here by tapping the sheet or by the sheet opening and starting itself.
        feedback.play(.acknowledged)

        // Anything playing would otherwise be transcribed as if she said it.
        // Remember that we interrupted it, so the episode is not silently lost
        // when the command turns out not to start anything new.
        interruptedPlayback = player.isPlaying
        if player.isPlaying { player.pause() }
        defer { resumeInterruptedPlayback() }

        do {
            state = .listening
            // A recogniser may start capture more than once — the older one
            // retries server-side — but she should be told to speak only once.
            var announced = false
            let listenStarted = ContinuousClock.now
            let transcript = try await speech.listen {
                guard !announced else { return }
                announced = true
                self.feedback.play(.listening)
            }
            attempt.listenSeconds = Self.seconds(since: listenStarted)
            // Listening worked, so whatever was missing has been granted.
            needsPermission = false
            let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            attempt.transcriptEmpty = heard.isEmpty
            guard !heard.isEmpty else {
                attempt.outcome = .noSpeech
                await fail(saying: "I did not hear anything. Tap and try again.")
                return
            }

            // Transport controls and the sleep timer resolve here, with no
            // network and no model. Sleep is checked first: its phrases are
            // the more specific of the two ("stop" is a pause, "stop in
            // twenty minutes" is not).
            if let sleep = SleepCommand.match(transcript) {
                attempt.outcome = .sleep
                attempt.sleepCommand = sleep == .cancel ? "cancel" : "after"
                await perform(sleep)
                return
            }
            if let transport = TransportCommand.match(transcript) {
                attempt.outcome = .transport
                attempt.transportCommand = String(describing: transport)
                perform(transport)
                return
            }

            state = .thinking
            attempt.commandSent = true
            let response = try await announcingDelay {
                try await self.api.command(
                    transcript: transcript, traceparent: attempt.traceparent())
            }
            attempt.outcome = Self.outcome(of: response)
            await handle(response)
        } catch is SpeechPermissionDenied {
            attempt.outcome = .permissionDenied
            // Distinct from every other failure: telling her to tap and try
            // again would be advice that can never work.
            needsPermission = true
            await fail(saying: Self.permissionMessage)
        } catch let error as APIError {
            attempt.outcome = .error
            attempt.error = "api"
            await fail(saying: error.spokenResponse)
        } catch {
            attempt.outcome = .error
            // The type, never the message: messages carry detail that has no
            // business in a column meant for grouping.
            attempt.error = String(describing: type(of: error))
            await fail(saying: "Sorry, I could not hear you. Please tap and try again.")
        }
    }

    /// What she got, in her terms rather than the protocol's.
    private static func outcome(of response: CommandResponse) -> VoiceAttempt.Outcome {
        switch response.action {
        case .playEpisode: .played
        case .setSpeed: .speed
        case .unknown: .spoken
        }
    }

    private static func seconds(since instant: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - instant
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Acted on immediately and silently: the audio stopping, starting or
    /// jumping is itself the confirmation, and a spoken "paused" would only
    /// delay the thing she asked for.
    private func perform(_ command: TransportCommand) {
        switch command {
        case .pause:
            // She asked for silence; carrying on afterwards would be maddening.
            interruptedPlayback = false
            player.pause()
        case .resume: player.resume()
        case .skipForward: player.skip(by: 30)
        case .skipBack: player.skip(by: -15)
        // Quarter steps: enough to notice, small enough to nudge repeatedly.
        case .faster: player.setPlaybackRate(min(player.playbackRate + 0.25, 2.0))
        case .slower: player.setPlaybackRate(max(player.playbackRate - 0.25, 0.5))
        case .normalSpeed: player.setPlaybackRate(1.0)
        }
        state = .idle
    }

    /// Unlike the transport controls, this is confirmed aloud: setting a timer
    /// makes no audible change at all, so silence would leave her with no way
    /// to know whether it took — and she is about to stop paying attention.
    private func perform(_ command: SleepCommand) async {
        switch command {
        case .after(let minutes):
            sleepTimer.start(minutes: minutes)
            await finish(saying: "I will stop in \(SleepTimer.spokenDuration(minutes: minutes)).")
        case .cancel:
            sleepTimer.cancel()
            await finish(saying: "Sleep timer off.")
        }
        // The episode she interrupted to say this carries on.
    }

    /// Puts back what she was listening to, unless something replaced it.
    private func resumeInterruptedPlayback() {
        guard interruptedPlayback else { return }
        interruptedPlayback = false
        if case .playing = state { return }  // a new episode took over
        player.resume()
    }

    private func handle(_ response: CommandResponse) async {
        switch response.action {
        case .unknown:
            await finish(saying: response.spokenResponse)

        case .setSpeed:
            guard let speed = response.speed else {
                await finish(saying: response.spokenResponse)
                return
            }
            player.setPlaybackRate(Float(speed))
            // Confirm aloud: playback is paused while she speaks, so unlike
            // pause/skip there is no audible change to hear yet.
            await finish(saying: response.spokenResponse)

        case .playEpisode:
            // Playable means streamable audio or article text to read aloud.
            guard let episode = response.episode,
                episode.audioURL != nil || episode.hasText == true
            else {
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

    /// Runs `work`, saying "one moment" aloud if it turns out to be slow.
    ///
    /// Waiting on the model is the one long silence in the interaction, and a
    /// silence she cannot see the cause of is indistinguishable from the app
    /// having missed her, or died. Nothing is said about a quick answer: the
    /// filler would only push the real reply further away.
    private func announcingDelay<T>(_ work: () async throws -> T) async throws -> T {
        let notice = Task {
            try? await Task.sleep(for: Self.noticeAfter)
            guard !Task.isCancelled else { return }
            // Deliberately not `say`: this is a holding line, not an answer,
            // so it should not become the caption she is left looking at.
            await self.speaker.speak("One moment.")
        }
        defer { notice.cancel() }
        do {
            let result = try await work()
            await settle(notice)
            return result
        } catch {
            await settle(notice)
            throw error
        }
    }

    /// Stops the holding line, but lets one already under way finish rather
    /// than cutting it off mid-word.
    private func settle(_ notice: Task<Void, Never>) async {
        notice.cancel()
        await notice.value
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
