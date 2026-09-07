import AppIntents
import Foundation
import Synchronization
import Testing

@testable import Hearful

private actor ShortcutTransport: DataTransport {
    let responses: [String: (Int, String)]
    var requests: [URLRequest] = []
    init(_ responses: [String: (Int, String)]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let (status, json) = responses[request.url!.path] ?? (503, "{}")
        return (
            Data(json.utf8),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
@Suite("Siri and Shortcuts")
struct ShortcutTests {
    private let episodeJSON = """
        {"id":104,"title":"History","audio_url":"https://example.test/audio.mp3","duration_seconds":1800,
         "position_seconds":321,"completed":false,"feed_title":"The History Show","has_text":false}
        """
    private func library(
        _ transport: ShortcutTransport, scope: @escaping @Sendable () -> String? = { "account-one" }
    ) -> ShortcutLibrary {
        ShortcutLibrary(
            api: HearfulAPI(baseURL: URL(string: "https://test.invalid")!, transport: transport),
            directory: URL.temporaryDirectory.appending(path: UUID().uuidString), scope: scope)
    }
    private func player(_ api: HearfulAPIProtocol = FakeAPI()) -> PlaybackCoordinator {
        PlaybackCoordinator(
            audio: AudioPlayer(), article: ArticlePlayer(api: api, synthesizer: SilentSynthesizer()))
    }

    @Test func searchOnlyCallsReadOnlyLibraryEndpoint() async throws {
        let transport = ShortcutTransport(["/search/episodes": (200, "[\(episodeJSON)]")])
        let found = try await library(transport).find("History")
        #expect(found.map(\.id) == [104])
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "GET")
        #expect(requests.first?.url?.path == "/search/episodes")
    }

    @Test func selectedEntityResolvesFullSavedPlaybackState() async throws {
        let transport = ShortcutTransport(["/episodes/104": (200, episodeJSON)])
        let chosen = try await ShortcutPlayback.resolve(
            id: 104, library: library(transport), player: player())
        #expect(chosen.positionSeconds == 321)
        #expect(chosen.completed == false)
        #expect(chosen.feedTitle == "The History Show")
        #expect(EpisodeEntity(chosen).source == "The History Show")
    }

    @Test func currentArticleUsesLivePlayerInsteadOfRefetchingStaleProgress() async throws {
        let transport = ShortcutTransport([:])
        let api = FakeAPI()
        api.articleText = String(repeating: "A paragraph of history.\n\n", count: 20)
        let player = player(api)
        let episode = Episode(
            id: 25, title: "Article", description: nil, audioURL: nil,
            durationSeconds: 100, publishedAt: nil, link: nil, positionSeconds: 40, hasText: true)
        player.restore(episode)
        let selected = try await ShortcutPlayback.resolve(id: 25, library: library(transport), player: player)
        #expect(selected == episode)
        #expect(await transport.requests.isEmpty)
        player.clear()
    }

    @Test func coldContinueUsesRememberedIdentifier() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        PlaybackRestore.remember(episodeID: 104, defaults: defaults)
        let transport = ShortcutTransport(["/episodes/104": (200, episodeJSON)])
        let episode = try await ShortcutPlayback.resolve(
            id: nil, library: library(transport), player: player(), defaults: defaults)
        #expect(episode.id == 104)
        #expect(episode.positionSeconds == 321)
    }

    @Test func missingIdentifierIsOmittedButServiceFailureIsNotHidden() async throws {
        let missing = ShortcutTransport([
            "/episodes/104": (404, "{}"),
            "/episodes/105": (200, episodeJSON.replacingOccurrences(of: "104", with: "105")),
        ])
        #expect(try await library(missing).episodes(ids: [104, 105]).map(\.id) == [105])
        let unavailable = ShortcutTransport(["/episodes/104": (503, "{}")])
        await #expect(throws: APIError.self) { try await library(unavailable).episodes(ids: [104]) }
    }

    @Test func cachedSuggestionsAreScopedToTheSession() async throws {
        let identity = Mutex<String?>("one")
        let transport = ShortcutTransport(["/episodes": (200, "[\(episodeJSON)]")])
        let library = library(transport, scope: { identity.withLock { $0 } })
        _ = try await library.suggestions()
        _ = try await library.suggestions()
        #expect(await transport.requests.count == 1)
        identity.withLock { $0 = "two" }
        _ = try await library.suggestions()
        #expect(await transport.requests.count == 2)
        identity.withLock { $0 = nil }
        await #expect(throws: ShortcutFailure.self) { try await library.suggestions() }
        library.invalidate()
    }

    @Test func filtersExcludePlayedAndUnknownDuration() throws {
        var item = try JSONDecoder().decode(Episode.self, from: Data(episodeJSON.utf8))
        #expect(
            FindListeningItemsIntent.filter([item], unheard: true, maximumMinutes: 30, limit: 10).count == 1)
        item.completed = true
        #expect(
            FindListeningItemsIntent.filter([item], unheard: true, maximumMinutes: nil, limit: 10).isEmpty)
        item.completed = false
        item.durationSeconds = nil
        #expect(
            FindListeningItemsIntent.filter([item], unheard: false, maximumMinutes: 30, limit: 10).isEmpty)
    }

    @Test func typedControlsRejectNonFiniteAndOutOfRangeValues() {
        #expect(throws: ShortcutFailure.self) { try ListeningControls.rate(.nan) }
        #expect(throws: ShortcutFailure.self) { try ListeningControls.rate(8) }
        #expect(throws: ShortcutFailure.self) { try ListeningControls.seconds(-1) }
        #expect(throws: ShortcutFailure.self) { try ListeningControls.seconds(.infinity) }
    }

    @Test func suppliedRequestNeverOpensMicrophone() async {
        let api = FakeAPI()
        api.response = CommandResponse(action: .unknown, spokenResponse: "Done.", episode: nil)
        let recorder = Recorder()
        let speech = FakeSpeech()
        let controller = VoiceController(
            api: api, speech: speech, speaker: FakeSpeaker(recorder),
            player: FakePlayer(recorder), feedback: FakeFeedback(recorder))
        await controller.beginCommand(transcript: "Find the history podcast")
        #expect(speech.listenCount == 0)
        #expect(api.transcripts == ["Find the history podcast"])
        #expect(!recorder.events.contains(.cue(.listening)))
    }

    @Test func suppliedRequestStillListensForClarification() async {
        let api = FakeAPI()
        api.responses = [
            CommandResponse(
                action: .unknown, spokenResponse: "Which show?", episode: nil, expectsReply: true),
            CommandResponse(action: .unknown, spokenResponse: "Found it.", episode: nil),
        ]
        let recorder = Recorder()
        let speech = FakeSpeech()
        speech.transcript = "The History Hour"
        let controller = VoiceController(
            api: api, speech: speech, speaker: FakeSpeaker(recorder),
            player: FakePlayer(recorder), feedback: FakeFeedback(recorder))
        await controller.beginCommand(transcript: "Find that show")
        #expect(speech.listenCount == 1)
        #expect(api.turnsSent.last?.contains(ConversationTurn(speaker: .app, text: "Which show?")) == true)
    }

    @Test func foregroundRecoveryKeepsOriginalReceipt() async {
        let api = FakeAPI()
        let context = VoiceSessionContext()
        context.pendingRequest = CommandRequest(transcript: "Follow History", requestID: "original-receipt")
        let recorder = Recorder()
        let speech = FakeSpeech()
        let controller = VoiceController(
            api: api, speech: speech, speaker: FakeSpeaker(recorder),
            player: FakePlayer(recorder), feedback: FakeFeedback(recorder), sessionContext: context)
        await controller.beginCommand(transcript: "Follow History", recovering: true)
        #expect(api.requests.first?.requestID == "original-receipt")
        #expect(speech.listenCount == 0)
        #expect(context.pendingRequest == nil)
    }

    @Test func failedTypedActionReusesReceiptOnRetry() async throws {
        let api = FakeAPI()
        let execution = ShortcutActionExecution(api: api, scope: { "account" })
        api.libraryActionError = APIError(underlying: "offline")
        await #expect(throws: APIError.self) { try await execution.run("dismiss", episodeID: 104) }
        api.libraryActionError = nil
        _ = try await execution.run("dismiss", episodeID: 104)
        #expect(api.libraryActionRequests.count == 2)
        #expect(api.libraryActionRequests[0].2 == api.libraryActionRequests[1].2)
        _ = try await execution.run("dismiss", episodeID: 104)
        #expect(api.libraryActionRequests[2].2 != api.libraryActionRequests[1].2)
        #expect(api.requests.isEmpty)
    }

    @Test func libraryActionUsesTypedEndpointAndReceipt() async throws {
        let transport = ShortcutTransport([
            "/actions": (200, "{\"action\":\"restore\",\"spoken_response\":\"Undone.\",\"episode\":null}")
        ])
        let api = HearfulAPI(baseURL: URL(string: "https://test.invalid")!, transport: transport)
        _ = try await api.libraryAction("undo", episodeID: nil, requestID: "same-receipt")
        let request = try #require(await transport.requests.first)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        #expect(request.httpMethod == "POST")
        #expect(body["request_id"] == "same-receipt")
        #expect(body["action"] == "undo")
    }
}

@MainActor
@Suite("Siri conversation", .serialized)
struct SiriConversationTests {
    @Test func asksClarificationAndSendsAnswerWithContext() async throws {
        let api = FakeAPI()
        api.userInfo = UserInfo(id: UUID().uuidString, displayName: nil, aiDataSharingConsented: true)
        api.responses = [
            CommandResponse(
                action: .unknown, spokenResponse: "Which publication?", episode: nil, expectsReply: true),
            CommandResponse(action: .unknown, spokenResponse: "Already following it.", episode: nil),
        ]
        var questions: [String] = []
        let result = try await ShortcutConversation.run(
            "Follow History", api: api, scopeProvider: { "test-session" },
            clarify: {
                questions.append($0)
                return "History Today"
            },
            foreground: { _ in Issue.record("No foreground handoff expected") })
        #expect(questions == ["Which publication?"])
        #expect(api.transcripts == ["Follow History", "History Today"])
        #expect(api.turnsSent.last?.last == ConversationTurn(speaker: .app, text: "Which publication?"))
        #expect(api.requests.allSatisfy { $0.requestID != nil })
        #expect(result.summary == "Already following it.")
        #expect(!result.continuedInApp)
    }

    @Test func consentHandoffPreservesTextWithoutSendingItToAI() async throws {
        VoicePrompt.clear()
        defer { VoicePrompt.clear() }
        let api = FakeAPI()
        var opened = false
        let result = try await ShortcutConversation.run(
            "Find a new history show", api: api, scopeProvider: { "test-session" },
            clarify: { _ in
                Issue.record("No clarification expected")
                return ""
            },
            foreground: { _ in
                opened = true
                #expect(!VoicePrompt.pending)
            })
        #expect(opened)
        #expect(api.requests.isEmpty)
        #expect(result.continuedInApp)
        #expect(VoicePrompt.takeInput()?.transcript == "Find a new history show")
    }

    @Test func cancelledForegroundHandoffLeavesNoRequestWaiting() async {
        VoicePrompt.clear()
        defer { VoicePrompt.clear() }
        await #expect(throws: CancellationError.self) {
            try await ShortcutConversation.run(
                "Follow a show", api: FakeAPI(), scopeProvider: { "test-session" },
                clarify: { _ in "" }, foreground: { _ in throw CancellationError() })
        }
        #expect(!VoicePrompt.pending)
        #expect(VoicePrompt.takeInput() == nil)
    }

    @Test func timedOutConversationHandsOffTheOriginalReceipt() async throws {
        VoicePrompt.clear()
        defer { VoicePrompt.clear() }
        let api = FakeAPI()
        api.userInfo = UserInfo(id: UUID().uuidString, displayName: nil, aiDataSharingConsented: true)
        api.commandGate = CommandGate()
        let result = try await ShortcutConversation.run(
            "Follow that publication", api: api, requestTimeout: 0.01, scopeProvider: { "test-session" },
            clarify: { _ in "" }, foreground: { _ in })
        let input = VoicePrompt.takeInput()
        #expect(result.continuedInApp)
        #expect(input?.transcript == "Follow that publication")
        #expect(input?.recovering == true)
        let context = VoiceSessionContext.forAccount(api.userInfo.id, server: AppConfiguration.apiBaseURL)
        #expect(context.pendingRequest?.requestID == api.requests.first?.requestID)
        #expect(!context.isExecuting)
        await api.commandGate?.release()
    }
}
