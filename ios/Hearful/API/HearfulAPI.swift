import Foundation

// The API layer is deliberately nonisolated: it holds no mutable state and is
// called from App Intents and background tasks as well as the UI.
nonisolated protocol HearfulAPIProtocol: Sendable {
    /// `nowPlayingEpisodeID` is what she is listening to as she speaks.
    /// Without it "mark this as played" has no referent: the backend knows
    /// her whole library and nothing about which part of it is in her ears.
    ///
    /// `traceparent` is W3C trace context, so the backend's own telemetry
    /// for this request joins the phone's rather than sitting beside it.
    /// `turns` carries what has already been said in this exchange, so an
    /// answer to a question the app asked arrives as the second half of a
    /// request rather than as an unrelated one.
    func command(
        transcript: String, nowPlayingEpisodeID: Int?, turns: [ConversationTurn],
        traceparent: String?
    ) async throws -> CommandResponse
    /// Text arrives as the model writes it, followed by the same final command
    /// result used by the non-streaming endpoint.
    nonisolated func commandStream(
        transcript: String, nowPlayingEpisodeID: Int?, turns: [ConversationTurn],
        traceparent: String?
    ) -> AsyncThrowingStream<CommandStreamEvent, Error>
    func episode(id: Int) async throws -> Episode
    func articleText(episodeID: Int) async throws -> EpisodeText
    func recentEpisodes(limit: Int) async throws -> [Episode]
    /// Empties Latest without deleting episodes or marking them as played.
    func clearLatest() async throws
    func shows() async throws -> [Show]
    /// One show's episodes, newest first — or the ones matching `query`.
    ///
    /// Searching happens on the backend because the app only ever holds the
    /// newest fifty, and the episode being looked for is usually older than
    /// that: a feed like In Our Time carries its archive back to 1998.
    func episodes(showID: Int, query: String?) async throws -> [Episode]
    func searchPodcasts(query: String) async throws -> [PodcastResult]
    func searchLibraryEpisodes(query: String) async throws -> [Episode]
    func searchPublicationOnWeb(query: String) async throws -> PodcastResult?
    func discoverFeeds(url: URL) async throws -> FeedDiscoveryResponse
    func previewFeed(url: URL) async throws -> FeedPreview
    func subscribe(feedURL: URL) async throws -> Show
    func unsubscribe(showID: Int) async throws
    /// Her private newsletter address, minted by the backend on first request.
    func newsletterAddress() async throws -> NewsletterAddress
    /// Senders that have written to that address and await her answer.
    func pendingNewsletters() async throws -> [PendingNewsletter]
    /// Follow a pending sender. Everything it has sent lands in Latest.
    func approveNewsletter(id: Int) async throws -> Show
    /// Refuse a pending sender for good; its mail is dropped from now on.
    func blockNewsletter(id: Int) async throws
    /// `authorizationCode` is Apple's single-use code, forwarded so the
    /// backend can hold something revocable for account deletion. Optional:
    /// sign-in works without it.
    func login(appleIdentityToken: String, authorizationCode: String?) async throws -> AuthResponse
    func logout() async throws
    func me() async throws -> UserInfo
    /// Records or withdraws the explicit choice required before a transcript
    /// and library context may be sent to the AI provider.
    func setAIDataSharing(granted: Bool) async throws -> UserInfo
    func deleteAccount() async throws
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws
    /// Files an episode: heard, put aside, or back in the list. A nil flag is
    /// left alone, so hiding one says nothing about whether she heard it.
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws
    /// One wide event describing a spoken request, including the ones that
    /// never got as far as `command`.
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String?) async throws
    /// A crash or hang, as the phone's own diagnostics described it.
    func reportDiagnostic(_ event: [String: any Sendable]) async throws
}

extension HearfulAPIProtocol {
    nonisolated func commandStream(
        transcript: String, nowPlayingEpisodeID: Int?, turns: [ConversationTurn],
        traceparent: String?
    ) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await command(
                        transcript: transcript, nowPlayingEpisodeID: nowPlayingEpisodeID,
                        turns: turns, traceparent: traceparent)
                    continuation.yield(.assistantDelta(response.spokenResponse))
                    continuation.yield(.result(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // Keeps test doubles that do not exercise Latest source-compatible.
    func clearLatest() async throws {
        throw APIError(underlying: "Clearing Latest is not implemented by this API client")
    }

    // Keeps small test doubles source-compatible; any test that exercises the
    // choice supplies a real implementation rather than accidentally passing.
    func setAIDataSharing(granted: Bool) async throws -> UserInfo {
        throw APIError(underlying: "AI data sharing is not implemented by this API client")
    }

    func searchLibraryEpisodes(query: String) async throws -> [Episode] { [] }

    func searchPublicationOnWeb(query: String) async throws -> PodcastResult? { nil }

    func discoverFeeds(url: URL) async throws -> FeedDiscoveryResponse {
        throw APIError(underlying: "Feed discovery is not implemented by this API client")
    }

    // Newsletters are a later addition; test doubles that predate them keep
    // compiling, and any test that exercises them supplies the real thing.
    func newsletterAddress() async throws -> NewsletterAddress {
        throw APIError(underlying: "Newsletters are not implemented by this API client")
    }

    func pendingNewsletters() async throws -> [PendingNewsletter] { [] }

    func approveNewsletter(id: Int) async throws -> Show {
        throw APIError(underlying: "Newsletters are not implemented by this API client")
    }

    func blockNewsletter(id: Int) async throws {
        throw APIError(underlying: "Newsletters are not implemented by this API client")
    }
}

extension Notification.Name {
    /// Posted whenever any request comes back 401: the stored session is dead
    /// (revoked, or wiped server-side) and the app should return to sign-in.
    nonisolated static let hearfulAuthRequired = Notification.Name("hearfulAuthRequired")
    /// Posted after subscribing (or unsubscribing) so the library reloads.
    nonisolated static let hearfulSubscriptionsChanged = Notification.Name(
        "hearfulSubscriptionsChanged")
    /// Posted after an episode is marked played, put aside or restored — by
    /// swipe or by voice. Carries `EpisodeFiling.Change` in its object.
    ///
    /// A notification rather than a shared object, because the two things that
    /// have to hear about it are a list on screen and the position reporter,
    /// which is owned by the auth controller and reachable from neither.
    nonisolated static let hearfulEpisodeFiled = Notification.Name("hearfulEpisodeFiled")
    /// Posted after Settings changes the API endpoint. Live clients switch on
    /// their next request; visible list screens rebuild so that request happens
    /// immediately instead of leaving an old offline result on screen.
    nonisolated static let hearfulServerChanged = Notification.Name("hearfulServerChanged")
}

/// The one thing HearfulAPI needs from the network. Injecting this rather than
/// a URLSession keeps tests free of global stubbing state, which matters
/// because the test runner executes them in parallel.
nonisolated protocol DataTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DataTransport {}

nonisolated struct HearfulAPI: HearfulAPIProtocol {
    private let fixedBaseURL: URL?
    /// A live client resolves this before each request, so changing away from
    /// a development server does not require every screen and singleton to be
    /// reconstructed first. Tests and special-purpose clients pass a fixed
    /// URL through the existing initializer.
    var baseURL: URL { fixedBaseURL ?? AppConfiguration.apiBaseURL }
    let transport: DataTransport

    /// Where the bearer token comes from. Static because the client is built
    /// fresh at every call site (views, intents, voice) and they must all see
    /// the same session; settable so tests can supply a fixed token.
    nonisolated(unsafe) static var tokenProvider: @Sendable () -> String? = {
        KeychainTokenStore.token
    }

    init(transport: DataTransport = URLSession.shared) {
        fixedBaseURL = nil
        self.transport = transport
    }

    init(baseURL: URL, transport: DataTransport = URLSession.shared) {
        fixedBaseURL = baseURL
        self.transport = transport
    }

    func command(
        transcript: String, nowPlayingEpisodeID: Int? = nil, turns: [ConversationTurn] = [],
        traceparent: String? = nil
    ) async throws -> CommandResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("command"))
        request.setValue(traceparent, forHTTPHeaderField: "traceparent")
        request.httpMethod = "POST"
        // Finding an unknown blog's feed is deliberately slow and thorough on
        // the backend (web search, verification); the default 60s would give
        // up on exactly the requests that need the time.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CommandRequest(
                transcript: transcript,
                nowPlayingEpisodeID: nowPlayingEpisodeID,
                turns: turns,
                country: Self.countryCode))
        return try await send(request)
    }

    nonisolated func commandStream(
        transcript: String, nowPlayingEpisodeID: Int? = nil,
        turns: [ConversationTurn] = [], traceparent: String? = nil
    ) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        guard let session = transport as? URLSession else {
            return fallbackCommandStream(
                transcript: transcript, nowPlayingEpisodeID: nowPlayingEpisodeID,
                turns: turns, traceparent: traceparent)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("command/stream"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(traceparent, forHTTPHeaderField: "traceparent")
                    if let token = Self.tokenProvider() {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try JSONEncoder().encode(
                        CommandRequest(
                            transcript: transcript,
                            nowPlayingEpisodeID: nowPlayingEpisodeID,
                            turns: turns,
                            country: Self.countryCode))

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError(underlying: "response was not HTTP")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        if http.statusCode == 401 {
                            NotificationCenter.default.post(name: .hearfulAuthRequired, object: nil)
                        }
                        throw APIError(
                            spokenResponse: Self.spokenResponse(from: data)
                                ?? APIError.genericSpokenResponse,
                            underlying: "HTTP \(http.statusCode)",
                            isAuthFailure: http.statusCode == 401)
                    }

                    for try await line in bytes.lines where !line.isEmpty {
                        let envelope = try Self.decoder.decode(
                            CommandStreamEnvelope.self, from: Data(line.utf8))
                        switch envelope.type {
                        case "assistant_delta":
                            if let text = envelope.text { continuation.yield(.assistantDelta(text)) }
                        case "result":
                            guard let response = envelope.response else {
                                throw APIError(underlying: "stream result was empty")
                            }
                            continuation.yield(.result(response))
                        case "error":
                            throw APIError(
                                spokenResponse: envelope.spokenResponse
                                    ?? APIError.genericSpokenResponse,
                                underlying: "streamed command failed")
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch let error as APIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: APIError(
                            spokenResponse: "I cannot reach the internet right now. Please try again shortly.",
                            underlying: error.localizedDescription))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    nonisolated private func fallbackCommandStream(
        transcript: String, nowPlayingEpisodeID: Int?, turns: [ConversationTurn],
        traceparent: String?
    ) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await command(
                        transcript: transcript, nowPlayingEpisodeID: nowPlayingEpisodeID,
                        turns: turns, traceparent: traceparent)
                    continuation.yield(.assistantDelta(response.spokenResponse))
                    continuation.yield(.result(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String?) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("events/voice"))
        request.setValue(traceparent, forHTTPHeaderField: "traceparent")
        request.httpMethod = "POST"
        // Short, and deliberately shorter than a command's. This is a record of
        // something already over; it must never be what she is waiting on.
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: event)
        try await perform(request)
    }

    func reportDiagnostic(_ event: [String: any Sendable]) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("events/diagnostic"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: event)
        try await perform(request)
    }

    func episode(id: Int) async throws -> Episode {
        let url = baseURL.appendingPathComponent("episodes").appendingPathComponent("\(id)")
        return try await send(URLRequest(url: url))
    }

    func articleText(episodeID: Int) async throws -> EpisodeText {
        let url = baseURL.appendingPathComponent("episodes")
            .appendingPathComponent("\(episodeID)")
            .appendingPathComponent("text")
        return try await send(URLRequest(url: url))
    }

    func recentEpisodes(limit: Int = 30) async throws -> [Episode] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("episodes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        return try await send(URLRequest(url: components.url!))
    }

    func clearLatest() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("episodes"))
        request.httpMethod = "DELETE"
        try await perform(request)
    }

    func shows() async throws -> [Show] {
        try await send(URLRequest(url: baseURL.appendingPathComponent("feeds")))
    }

    func episodes(showID: Int, query: String? = nil) async throws -> [Episode] {
        let url = baseURL.appendingPathComponent("feeds")
            .appendingPathComponent("\(showID)")
            .appendingPathComponent("episodes")
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return try await send(URLRequest(url: url))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return try await send(URLRequest(url: components.url!))
    }

    func searchPodcasts(query: String) async throws -> [PodcastResult] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search/podcasts"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        if let country = Self.countryCode {
            components.queryItems?.append(URLQueryItem(name: "country", value: country))
        }
        return try await send(URLRequest(url: components.url!))
    }

    func searchLibraryEpisodes(query: String) async throws -> [Episode] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search/episodes"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return try await send(URLRequest(url: components.url!))
    }

    func searchPublicationOnWeb(query: String) async throws -> PodcastResult? {
        var request = URLRequest(url: baseURL.appendingPathComponent("search/publications"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["query": query])
        return try await send(request)
    }

    func discoverFeeds(url: URL) async throws -> FeedDiscoveryResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("feeds/discover"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": url])
        return try await send(request)
    }

    func previewFeed(url: URL) async throws -> FeedPreview {
        var request = URLRequest(url: baseURL.appendingPathComponent("feeds/preview"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": url])
        return try await send(request)
    }

    func subscribe(feedURL: URL) async throws -> Show {
        var request = URLRequest(url: baseURL.appendingPathComponent("feeds"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": feedURL])
        return try await send(request)
    }

    func unsubscribe(showID: Int) async throws {
        let url = baseURL.appendingPathComponent("feeds").appendingPathComponent("\(showID)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        try await perform(request)
    }

    func newsletterAddress() async throws -> NewsletterAddress {
        try await send(URLRequest(url: baseURL.appendingPathComponent("newsletters/address")))
    }

    func pendingNewsletters() async throws -> [PendingNewsletter] {
        try await send(URLRequest(url: baseURL.appendingPathComponent("newsletters/pending")))
    }

    func approveNewsletter(id: Int) async throws -> Show {
        let url = baseURL.appendingPathComponent("newsletters")
            .appendingPathComponent("\(id)")
            .appendingPathComponent("approve")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return try await send(request)
    }

    func blockNewsletter(id: Int) async throws {
        let url = baseURL.appendingPathComponent("newsletters")
            .appendingPathComponent("\(id)")
            .appendingPathComponent("block")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        try await perform(request)
    }

    func login(appleIdentityToken: String, authorizationCode: String?) async throws -> AuthResponse
    {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/apple"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["identity_token": appleIdentityToken]
        if let authorizationCode {
            body["authorization_code"] = authorizationCode
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    func logout() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/logout"))
        request.httpMethod = "POST"
        try await perform(request)
    }

    func me() async throws -> UserInfo {
        try await send(URLRequest(url: baseURL.appendingPathComponent("me")))
    }

    func setAIDataSharing(granted: Bool) async throws -> UserInfo {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("me/ai-data-sharing"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["granted": granted])
        return try await send(request)
    }

    func deleteAccount() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("me"))
        request.httpMethod = "DELETE"
        try await perform(request)
    }

    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws {
        let url = baseURL.appendingPathComponent("episodes")
            .appendingPathComponent("\(episodeID)")
            .appendingPathComponent("position")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PositionUpdate(positionSeconds: seconds, completed: completed))
        try await perform(request)
    }

    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws {
        let url = baseURL.appendingPathComponent("episodes")
            .appendingPathComponent("\(episodeID)")
            .appendingPathComponent("state")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            EpisodeStateUpdate(played: played, dismissed: dismissed))
        try await perform(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await perform(request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(underlying: "could not decode response: \(error)")
        }
    }

    @discardableResult
    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        if let token = Self.tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw APIError(
                spokenResponse: "I cannot reach the internet right now. Please try again shortly.",
                underlying: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError(underlying: "response was not HTTP")
        }
        if http.statusCode == 401 {
            NotificationCenter.default.post(name: .hearfulAuthRequired, object: nil)
            throw APIError(
                spokenResponse: Self.spokenResponse(from: data)
                    ?? "Please open Magpie and sign in.",
                underlying: "HTTP 401",
                isAuthFailure: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(
                // Prefer the sentence the backend wrote; fall back to a generic one.
                spokenResponse: Self.spokenResponse(from: data) ?? APIError.genericSpokenResponse,
                underlying: "HTTP \(http.statusCode)")
        }
        return data
    }

    private static func spokenResponse(from data: Data) -> String? {
        try? JSONDecoder().decode(ErrorEnvelope.self, from: data).detail?.spokenResponse
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // The backend emits both plain and fractional-second timestamps
            // depending on what the feed provided, so accept either.
            for formatter in [fractionalFormatter, plainFormatter] {
                if let date = formatter.date(from: text) { return date }
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unparsable date: \(text)"))
        }
        return decoder
    }()

    // nonisolated(unsafe) is honest here: ISO8601DateFormatter is documented
    // thread-safe (unlike DateFormatter), the compiler just cannot know that.
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainFormatter = ISO8601DateFormatter()

    private static var countryCode: String? {
        Locale.current.region?.identifier
    }
}
