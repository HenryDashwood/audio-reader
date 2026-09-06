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
    /// Delivers the recogniser's best current text whenever it changes. The
    /// value is a replacement, not a suffix: dictation is allowed to revise
    /// earlier words as more audio arrives.
    func listen(
        onReady: @MainActor () -> Void,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String
    func cancel()
    func finishListening()
    func configure(vocabulary: [String], onCaptureEnded: @escaping @MainActor () -> Void)
}

extension SpeechRecognizing {
    func finishListening() {}
    func configure(vocabulary: [String], onCaptureEnded: @escaping @MainActor () -> Void) {}

    func listen() async throws -> String { try await listen(onReady: {}) }

    func listen(
        onReady: @MainActor () -> Void,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        try await listen(onReady: onReady)
    }
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
    /// What is loaded, playing or paused. Sent with every spoken request:
    /// "mark this as played" has no referent without it.
    var currentEpisode: Episode? { get }
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
    case preparing
    case listening
    case finalizing
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

    /// How many times one exchange may go round after the first question.
    ///
    /// A ceiling rather than a loop, because the failure it guards against is
    /// the app asking her the same thing over and over with the microphone
    /// open. Three is generous: a request that has not been understood by the
    /// fourth attempt is not going to be, and being handed back the screen is
    /// a better answer than being asked again.
    static let maxFollowUps = 3

    /// What she is told when listening is not permitted. Long, unlike every
    /// other spoken line here, because it is the only one that has to carry
    /// instructions she cannot read off the screen.
    static let permissionMessage = """
        Magpie needs permission to listen. Open the Settings app, choose \
        Magpie, and turn on Microphone and Speech Recognition.
        """

    @Published private(set) var state: VoiceState = .idle
    @Published private(set) var lastSpokenResponse = ""
    /// The exchange so far: what she said, and what the app said back.
    ///
    /// Sent with each request, so a clarifying question and its answer are one
    /// request in two halves rather than two unrelated ones — and shown on the
    /// sheet, because the thing she cannot otherwise check is what the app
    /// believes it heard. A misheard word is obvious on screen and invisible
    /// from the answer.
    @Published private(set) var conversation = Conversation()
    /// The two unfinished lines shown like live dictation. They remain out of
    /// Conversation until final, so a changing partial is never sent back to
    /// the model as settled history.
    @Published private(set) var liveUserText = ""
    @Published private(set) var liveAssistantText = ""
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
    /// Tests control this delay so runner load cannot turn a prompt fake
    /// response into a slow request with an extra progress cue.
    private let progressDelay: @MainActor (Duration) async throws -> Void
    private var commandTask: Task<Void, Never>?
    private var commandID: UUID?
    private let sessionContext: VoiceSessionContext
    private var pendingRequest: CommandRequest? {
        get { sessionContext.pendingRequest }
        set { sessionContext.pendingRequest = newValue }
    }
    private var recentActions: [String] {
        get { sessionContext.recentActions }
        set { sessionContext.recentActions = newValue }
    }
    var viewedEpisode: Episode?
    var vocabulary: [String] = []
    private var isBusy: Bool { commandTask != nil }
    /// True while an episode has been paused only so she could be heard.
    private var interruptedPlayback = false
    /// True once the sheet has gone while a command was still in flight.
    ///
    /// Checked at every point the command picks up again rather than left to
    /// unwind on its own, because nothing here stops by itself: the recogniser
    /// waits out its silence timer, the backend answers, and the sentence gets
    /// spoken to a room where nobody asked anything.
    private var isCancelled: Bool { Task.isCancelled }

    init(
        api: HearfulAPIProtocol, speech: SpeechRecognizing, speaker: Speaking,
        player: AudioPlaying, feedback: FeedbackPlaying, sleepTimer: SleepTimer = .shared,
        telemetry: TelemetryReporting? = nil, sessionContext: VoiceSessionContext = VoiceSessionContext(),
        progressDelay: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sessionContext = sessionContext
        self.conversation = sessionContext.conversation
        self.api = api
        self.speech = speech
        self.speaker = speaker
        self.player = player
        self.feedback = feedback
        self.sleepTimer = sleepTimer
        self.telemetry = telemetry
        self.progressDelay = progressDelay
    }

    /// Listens, acts, and keeps going for as long as the answer was a question.
    ///
    /// One tap is one exchange, not one sentence. When the backend asks which
    /// show she meant, the microphone opens again on its own and her answer is
    /// sent with the question attached — which is the difference between a
    /// two-sentence request and two requests, and the difference she was
    /// paying for before: every clarification the app asked for was a question
    /// it then could not use the answer to.
    func beginCommand() async {
        // Taps are easy to double up when you cannot see the screen.
        guard !isBusy else { return }
        let id = UUID()
        commandID = id
        let task = Task { await self.runCommand(id: id) }
        commandTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if commandID == id {
            commandTask = nil
            commandID = nil
        }
    }

    private func runCommand(id: UUID) async {
        guard !Task.isCancelled else { return }
        // A tap after a long silence starts a subject rather than continuing
        // one. Checked here rather than on a timer so the transcript stays on
        // screen as long as she leaves the sheet open, and is dropped only at
        // the moment it would otherwise be read as context.
        conversation.forgetIfStale()

        // Before anything slow happens: confirm we are on it — whether she got
        // here by tapping the sheet or by the sheet opening and starting
        // itself. Only for the first turn of an exchange: on a follow-up the
        // question she has just been asked is the acknowledgement, and a tone
        // on top of it would be noise between a question and its answer.
        feedback.play(.acknowledged)

        // Anything playing would otherwise be transcribed as if she said it.
        // Remember that we interrupted it, so the episode is not silently lost
        // when the command turns out not to start anything new. Once for the
        // whole exchange: it comes back when the exchange ends, however many
        // turns that took.
        interruptedPlayback = player.isPlaying
        if player.isPlaying { player.pause() }
        defer { if commandID == id { resumeInterruptedPlayback(); sessionContext.conversation = conversation } }

        for _ in 0...Self.maxFollowUps {
            // Anything but a question ends it: she got what she asked for, or
            // was told why not. Cancellation ends it too — a question asked of
            // a sheet that has gone is not one to reopen the microphone for.
            guard await takeTurn(id: id) == .expectsReply, !isCancelled else { return }
        }
    }

    /// What a turn leaves behind: an exchange that is over, or one waiting on
    /// her.
    private enum TurnOutcome {
        case done
        case expectsReply
    }

    /// One listen, one answer. Everything that can go wrong with a spoken
    /// request goes wrong in here, and each pass is its own telemetry row.
    private func takeTurn(id: UUID) async -> TurnOutcome {
        defer { if commandID == id { speech.cancel() } }
        // One wide event per spoken turn, opened here and sent once at the
        // end however it ends — including the ends that never reach the
        // backend, which were invisible until this existed.
        let attempt = VoiceAttempt()
        // Which turn of the exchange this was. A first ask and an answer to a
        // question are different requests with different failure modes, and
        // from a single row they used to look identical.
        attempt.conversationTurns = conversation.turns.count
        VoiceAttempt.current = attempt
        defer {
            if VoiceAttempt.current === attempt { VoiceAttempt.current = nil }
            telemetry?.report(attempt)
        }

        do {
            // Fetching a provider credential and opening the audio route can
            // take a moment. Calling that "Listening" invites her to speak
            // before a microphone exists, which loses the beginning of the
            // command. Only onReady is the real go-ahead.
            state = .preparing
            // A recogniser may start capture more than once — the older one
            // retries server-side — but she should be told to speak only once.
            var announced = false
            var bookended = false
            let listenStarted = ContinuousClock.now
            liveUserText = ""
            liveAssistantText = ""
            speech.configure(vocabulary: recognitionVocabulary) { [weak self] in
                guard let self, self.commandID == id else { return }
                attempt.markCaptureEnded()
                self.state = .finalizing
                if !self.liveUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bookended = true
                    self.feedback.play(.processing)
                }
            }
            let transcript = try await withVoiceDeadline(seconds: 90) {
                try await self.speech.listen(
                onReady: {
                    guard !announced, self.commandID == id else { return }
                    announced = true
                    self.state = .listening
                    self.feedback.play(.listening)
                },
                onPartial: { text in
                    guard self.commandID == id else { return }
                    self.liveUserText = text
                })
            }
            attempt.listenSeconds = Self.seconds(since: listenStarted)
            // Cancelling a recogniser mid-turn is how closing the sheet ends
            // the wait, and the analyser answers that by handing back whatever
            // it had — nothing. Left to carry on, this is precisely the path
            // that says "I did not hear anything" to a sheet that is no longer
            // there. The attempt keeps its default outcome of `abandoned`.
            guard !isCancelled else { return .done }
            // Listening worked, so whatever was missing has been granted.
            needsPermission = false
            let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            attempt.transcriptEmpty = heard.isEmpty
            guard !heard.isEmpty else {
                attempt.outcome = .noSpeech
                // Ends the exchange rather than asking again. A question she
                // has answered with silence does not get a better answer for
                // being repeated, and repeating it is how a clarification
                // turns into the app talking to an empty room.
                await fail(saying: "I did not hear anything. Tap and try again.")
                return .done
            }
            // Bookend listening only when there is a request to handle. This
            // includes local commands, before any response or network wait.
            state = .thinking
            if !bookended { feedback.play(.processing) }

            // Replace the last live guess with the recogniser's final answer
            // before committing it. The settled line on screen is therefore
            // byte-for-byte the text sent below, including any proper noun
            // Apple corrected while finalising the audio.
            liveUserText = heard
            // On screen from here on, whether or not it reaches the network.
            // What the app thought it heard is the one thing she cannot check
            // by listening, and a misheard word explains almost every answer
            // that looks like the model being stupid.
            conversation.sheSaid(heard)
            liveUserText = ""

            // Transport controls and the sleep timer resolve here, with no
            // network and no model. Sleep is checked first: its phrases are
            // the more specific of the two ("stop" is a pause, "stop in
            // twenty minutes" is not).
            let simplePhrase = heard.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if ["undo that", "undo last action"].contains(simplePhrase), let rate = sessionContext.undoSpeed {
                player.setPlaybackRate(rate)
                sessionContext.undoSpeed = nil
                await finish(saying: "Back to \(rate) times speed.")
                return .done
            }
            if let sleep = SleepCommand.match(heard) {
                sessionContext.undoSpeed = nil
                attempt.outcome = .sleep
                attempt.sleepCommand = sleep == .cancel ? "cancel" : "after"
                await perform(sleep)
                return .done
            }
            if let transport = TransportCommand.match(heard) {
                attempt.outcome = .transport
                attempt.transportCommand = String(describing: transport)
                perform(transport)
                if case .speed(let rate) = transport {
                    await finish(saying: "\(rate) times speed.")
                }
                return .done
            }

            sessionContext.undoSpeed = nil
            attempt.commandSent = true
            // Captured before the request rather than read inside it: what is
            // playing is what she was listening to when she spoke, and by the
            // time the answer comes back it may not be.
            let nowPlaying = player.currentEpisode?.id
            // Everything except the line she has just spoken, which travels as
            // the transcript.
            let earlier = conversation.payload.dropLast()
            var response: CommandResponse?
            let recovery = ["try again", "did that work", "what happened", "check that request"].contains(
                heard.lowercased().trimmingCharacters(in: .punctuationCharacters))
            let request = recovery ? pendingRequest ?? CommandRequest(transcript: heard) : CommandRequest(
                transcript: heard, requestID: UUID().uuidString, viewedEpisodeID: viewedEpisode?.id,
                recentActions: recentActions, nowPlayingEpisodeID: nowPlaying, turns: Array(earlier))
            pendingRequest = request
            let progress = Task {
                do { try await self.progressDelay(.seconds(8)) } catch { return }
                guard !Task.isCancelled, self.commandID == id else { return }
                self.feedback.play(.working)
            }
            defer { progress.cancel() }
            for try await event in api.commandStream(request: request, traceparent: attempt.traceparent())
            {
                guard !isCancelled else { return .done }
                switch event {
                case .assistantDelta(let text):
                    liveAssistantText += text
                case .result(let result):
                    response = result
                }
            }
            guard let response else {
                throw APIError(underlying: "stream ended without a command result")
            }
            guard !isCancelled else { return .done }
            progress.cancel()
            attempt.markResponse()
            attempt.outcome = Self.outcome(of: response)
            await handle(response)
            // Keep the receipt recoverable if she interrupts the confirmation
            // before client-side playback or speed changes have been applied.
            guard !isCancelled else { return .done }
            pendingRequest = nil
            recentActions += (response.actions?.isEmpty == false ? response.actions! : [response]).map {
                "\($0.action.rawValue): \($0.spokenResponse)" + ($0.episode.map { " [episode_id=\($0.id)]" } ?? "")
            }
            recentActions = Array(recentActions.suffix(8))
            return response.expectsReply == true ? .expectsReply : .done
        } catch _ where isCancelled {
            // The recognisers that fail rather than return on cancellation end
            // up here. Our own doing, so it is neither announced nor counted
            // as an error — the outcome stays `abandoned`.
            return .done
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
            speech.cancel()
            attempt.outcome = .error
            // The type, never the message: messages carry detail that has no
            // business in a column meant for grouping.
            attempt.error = String(describing: type(of: error))
            await fail(saying: "Sorry, I could not hear you. Please tap and try again.")
        }
        // Every path that lands here has failed and said so. None of them is a
        // question, so the microphone stays shut and she has the screen back.
        return .done
    }

    /// Closing the sheet ends whatever it started.
    ///
    /// Without this the microphone stays open after the sheet has gone, and
    /// several seconds later the recogniser gives up and the app announces "I
    /// did not hear anything" — to someone who has stopped asking, and who
    /// cannot see that the sheet closed. Worse, it arrives long enough after
    /// the fact to sound like an answer to whatever she said next.
    func cancel() {
        guard isBusy else { return }
        // A command that reached playback has already done what she asked; the
        // sheet closes itself the moment it does. Unwinding here would stop
        // the episode it has just started and put back the one before it.
        if case .playing = state { return }

        if state == .thinking, let requestID = pendingRequest?.requestID {
            Task { await self.api.cancelCommand(requestID: requestID) }
        }
        commandTask?.cancel()
        commandTask = nil
        commandID = nil
        sessionContext.conversation = conversation
        speech.cancel()
        // Cuts off a confirmation mid-word, which is right: she has left.
        speaker.stop()
        state = .idle
        resumeInterruptedPlayback()
        // What she was listening to comes back either way — `beginCommand`
        // puts it back as it unwinds, exactly as it does for a failure.
    }

    /// The primary control ends capture, or interrupts a response to ask again.
    func activate() async {
        if state == .listening {
            speech.finishListening()
        } else {
            if isBusy { cancel() }
            await beginCommand()
        }
    }

    private var recognitionVocabulary: [String] {
        var words = [player.currentEpisode?.title, player.currentEpisode?.feedTitle].compactMap { $0 }
        words += vocabulary
        if let viewedEpisode { words.append(viewedEpisode.title) }
        words += conversation.turns.suffix(4).map(\.text)
        return Array(words.prefix(100))
    }

    /// What she got, in her terms rather than the protocol's.
    private static func outcome(of response: CommandResponse) -> VoiceAttempt.Outcome {
        switch response.action {
        case .playEpisode: .played
        case .setSpeed: .speed
        case .markPlayed, .dismiss, .restore: .filed
        case .subscribed, .unsubscribed, .unknown: .spoken
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
        case .faster, .slower, .normalSpeed, .speed: sessionContext.undoSpeed = player.playbackRate
        default: sessionContext.undoSpeed = nil
        }
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
        case .seek(let seconds): player.skip(by: seconds)
        case .speed(let rate): player.setPlaybackRate(rate)
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
        if let actions = response.actions, !actions.isEmpty {
            // Prepare and confirm once, then apply all effects before exposing
            // .playing (which dismisses the sheet and ends this exchange).
            for action in actions where action.action == .playEpisode {
                if let episode = action.episode { player.prepare(episode) }
            }
            await say(response.spokenResponse)
            guard !isCancelled else { return }
            var playing: Episode?
            for action in actions {
                switch action.action {
                case .playEpisode:
                    guard let episode = action.episode else { continue }
                    do { try player.play(episode); playing = episode }
                    catch { await fail(saying: "Sorry, that episode would not play."); return }
                case .setSpeed:
                    if let speed = action.speed { player.setPlaybackRate(Float(speed)) }
                case .subscribed, .unsubscribed:
                    NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
                case .markPlayed, .dismiss, .restore:
                    if let episode = action.episode, let filing = action.action.filing {
                        filing.broadcast(episodeID: episode.id)
                        if filing.hidesFromLatest, player.currentEpisode?.id == episode.id {
                            player.pause(); interruptedPlayback = false; playing = nil
                        }
                    }
                case .unknown: break
                }
            }
            state = playing.map(VoiceState.playing) ?? .idle
            return
        }
        switch response.action {
        case .unknown:
            await finish(saying: response.spokenResponse)

        case .subscribed, .unsubscribed:
            NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
            await finish(saying: response.spokenResponse)

        case .markPlayed, .dismiss, .restore:
            await file(response)

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
            // She closed the sheet while it was being confirmed. Starting the
            // episode now would be answering a question she withdrew, so what
            // she was listening to before comes back instead.
            guard !isCancelled else { return }
            do {
                try player.play(episode)
                state = .playing(episode)
            } catch {
                await fail(saying: "Sorry, that episode would not play.")
            }
        }
    }

    /// The backend has already filed the episode; the app catches up.
    ///
    /// Nothing is played or stopped on the strength of the sentence alone —
    /// the episode in the response is the row that actually changed, and the
    /// only thing worth acting on.
    private func file(_ response: CommandResponse) async {
        guard let episode = response.episode, let filing = response.action.filing else {
            await finish(saying: response.spokenResponse)
            return
        }
        // Taking the episode she is listening to out of her list, and then
        // carrying on playing it, would answer "I have heard this" by playing
        // more of it — and thirty seconds later the position reporter would
        // write its own idea of the episode's state over hers.
        if filing.hidesFromLatest, player.currentEpisode?.id == episode.id {
            interruptedPlayback = false
            player.pause()
        }
        filing.broadcast(episodeID: episode.id)
        await finish(saying: response.spokenResponse)
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
            guard !Task.isCancelled, !self.isCancelled else { return }
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
        // The last line of defence for a sheet that has gone: a sentence
        // started now would be talking to nobody, and would still be talking
        // when she is doing something else.
        guard !isCancelled else { return }
        lastSpokenResponse = text
        // Recorded here rather than from the response, because this is the one
        // place every spoken line passes through: an apology the app decided on
        // by itself reaches the transcript exactly like a sentence the backend
        // sent, and what is on screen is what she actually heard. The holding
        // line does not come through here, which is why it stays out.
        conversation.appSaid(text)
        liveAssistantText = ""
        await speaker.speak(text)
    }

    private func finish(saying text: String) async {
        await say(text)
        guard !isCancelled else { return }
        state = .idle
    }

    private func fail(saying text: String) async {
        guard !isCancelled else { return }
        feedback.play(.failed)
        await finish(saying: text)
    }
}
