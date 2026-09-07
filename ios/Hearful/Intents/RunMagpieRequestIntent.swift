import AppIntents
import Foundation

struct MagpieRequestResult: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Magpie Response")
    @Property(title: "Summary") var summary: String
    @Property(title: "Listening item") var item: EpisodeEntity?
    @Property(title: "Continued in app") var continuedInApp: Bool
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(summary)") }
    init() {
        summary = ""
        continuedInApp = false
    }
}

struct RunMagpieRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Magpie Request"
    static let description = IntentDescription(
        "Handles a dictated or written request without asking you to repeat it in Magpie.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    @Parameter(title: "Request", requestValueDialog: "What would you like Magpie to do?") var request: String
    static var parameterSummary: some ParameterSummary { Summary("Ask Magpie to \(\.$request)") }
    init() {}
    init(request: String) { self.request = request }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MagpieRequestResult> & ProvidesDialog {
        let result = try await ShortcutConversation.run(
            request,
            clarify: { try await $request.requestValue(IntentDialog("\($0)")) },
            foreground: { try await continueInForeground(IntentDialog("\($0)")) })
        return .result(value: result, dialog: IntentDialog("\(result.summary)"))
    }
}

@MainActor
enum ShortcutConversation {
    static func run(
        _ transcript: String, api: HearfulAPIProtocol = HearfulAPI(),
        requestTimeout: Double = 20,
        scopeProvider: @escaping @Sendable () -> String? = { ShortcutScope.current },
        clarify: @MainActor (String) async throws -> String,
        foreground: @MainActor (String) async throws -> Void
    ) async throws -> MagpieRequestResult {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ShortcutFailure(message: "Please provide a request for Magpie.") }
        do {
            if let local = try await ShortcutLocalRequest.perform(text, foreground: foreground) {
                return local
            }
            let scope = scopeProvider()
            let user = try await api.me()
            guard scopeProvider() == scope else { throw CancellationError() }
            if !user.aiDataSharingConsented {
                try await foreground("Opening Magpie to review your AI data-sharing choice.")
                VoicePrompt.request(transcript: text)
                let result = MagpieRequestResult()
                result.summary = "Your request is ready in Magpie."
                result.continuedInApp = true
                return result
            }
            let context = VoiceSessionContext.forAccount(user.id, server: AppConfiguration.apiBaseURL)
            guard !context.isExecuting else {
                throw ShortcutFailure(
                    message: "Magpie is already handling a request. Please let it finish first.")
            }
            let executionID = UUID()
            context.executionID = executionID
            defer { if context.executionID == executionID { context.executionID = nil } }
            context.conversation.forgetIfStale()
            var heard = text
            for turn in 0...VoiceController.maxFollowUps {
                try Task.checkCancellation()
                guard scopeProvider() == scope else { throw CancellationError() }
                let recover = ["try again", "did that work", "what happened", "check that request"].contains(
                    heard.lowercased().trimmingCharacters(in: .punctuationCharacters))
                let request =
                    recover && context.pendingRequest != nil
                    ? context.pendingRequest!
                    : CommandRequest(
                        transcript: heard, requestID: UUID().uuidString,
                        viewedEpisodeID: ShortcutNavigation.viewedEpisodeID,
                        recentActions: context.recentActions,
                        nowPlayingEpisodeID: PlaybackCoordinator.shared.currentEpisode?.id,
                        turns: context.conversation.payload)
                context.pendingRequest = request
                context.conversation.sheSaid(heard)
                ShortcutUndo.clear()
                let response: CommandResponse
                do {
                    response = try await withVoiceDeadline(seconds: requestTimeout) {
                        try await CommandExecution.response(api: api, request: request)
                    }
                } catch is VoiceTimeout {
                    // The server keeps the receipt alive. Foreground recovery
                    // reuses its identity, never submits the mutation twice.
                    context.executionID = nil
                    do { try await foreground("Opening Magpie to finish your request.") } catch {
                        if let id = request.requestID { await api.cancelCommand(requestID: id) }
                        throw error
                    }
                    VoicePrompt.request(transcript: request.transcript, recovering: true)
                    let result = MagpieRequestResult()
                    result.summary = "Continuing your request in Magpie."
                    result.continuedInApp = true
                    return result
                } catch is CancellationError {
                    if let id = request.requestID { await api.cancelCommand(requestID: id) }
                    throw CancellationError()
                }
                guard scopeProvider() == scope else { throw CancellationError() }
                let result = MagpieRequestResult()
                for action in CommandExecution.actions(response) {
                    try Task.checkCancellation()
                    switch action.action {
                    case .playEpisode:
                        guard let episode = action.episode else {
                            throw ShortcutFailure(message: "No listening item was returned.")
                        }
                        let chosen = ShortcutPlayback.chooseFresh(episode)
                        try await ShortcutPlayback.start(chosen) {
                            try await foreground("Opening Magpie to start listening.")
                        }
                        result.item = EpisodeEntity(chosen)
                    case .setSpeed:
                        if let speed = action.speed {
                            let player = PlaybackCoordinator.shared
                            let rate = try ListeningControls.rate(speed)
                            ShortcutUndo.rememberSpeed(player.playbackRate, applied: rate, mode: player.mode)
                            player.setPlaybackRate(rate)
                        }
                    default: CommandExecution.broadcast(action, player: PlaybackCoordinator.shared)
                    }
                }
                context.pendingRequest = nil
                context.conversation.appSaid(response.spokenResponse)
                context.recentActions = Array(
                    (context.recentActions
                        + CommandExecution.actions(response).map {
                            "\($0.action.rawValue): \($0.spokenResponse)"
                                + ($0.episode.map { " [episode_id=\($0.id)]" } ?? "")
                        }).suffix(8))
                result.summary = response.spokenResponse
                if response.expectsReply != true { return result }
                if turn == VoiceController.maxFollowUps {
                    throw ShortcutFailure(
                        message: "I still need more detail. Open Ask Magpie to continue this conversation.")
                }
                heard = try await clarify(response.spokenResponse)
            }
            throw ShortcutFailure(message: "Please try asking Magpie again.")
        } catch { throw ShortcutFailure.explaining(error) }
    }
}
