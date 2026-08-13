import Foundation

// The API layer is deliberately nonisolated: it holds no mutable state and is
// called from App Intents and background tasks as well as the UI.
nonisolated protocol HearfulAPIProtocol: Sendable {
    func command(transcript: String) async throws -> CommandResponse
    func episode(id: Int) async throws -> Episode
    func articleText(episodeID: Int) async throws -> EpisodeText
    func recentEpisodes(limit: Int) async throws -> [Episode]
    func shows() async throws -> [Show]
    func episodes(showID: Int) async throws -> [Episode]
    func searchPodcasts(query: String) async throws -> [PodcastResult]
    func previewFeed(url: URL) async throws -> FeedPreview
    func subscribe(feedURL: URL) async throws -> Show
    func unsubscribe(showID: Int) async throws
    /// `authorizationCode` is Apple's single-use code, forwarded so the
    /// backend can hold something revocable for account deletion. Optional:
    /// sign-in works without it.
    func login(appleIdentityToken: String, authorizationCode: String?) async throws -> AuthResponse
    func logout() async throws
    func me() async throws -> UserInfo
    func deleteAccount() async throws
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws
}

extension Notification.Name {
    /// Posted whenever any request comes back 401: the stored session is dead
    /// (revoked, or wiped server-side) and the app should return to sign-in.
    nonisolated static let hearfulAuthRequired = Notification.Name("hearfulAuthRequired")
    /// Posted after subscribing (or unsubscribing) so the library reloads.
    nonisolated static let hearfulSubscriptionsChanged = Notification.Name(
        "hearfulSubscriptionsChanged")
}

/// The one thing HearfulAPI needs from the network. Injecting this rather than
/// a URLSession keeps tests free of global stubbing state, which matters
/// because the test runner executes them in parallel.
nonisolated protocol DataTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DataTransport {}

nonisolated struct HearfulAPI: HearfulAPIProtocol {
    let baseURL: URL
    let transport: DataTransport

    /// Where the bearer token comes from. Static because the client is built
    /// fresh at every call site (views, intents, voice) and they must all see
    /// the same session; settable so tests can supply a fixed token.
    nonisolated(unsafe) static var tokenProvider: @Sendable () -> String? = {
        KeychainTokenStore.token
    }

    init(baseURL: URL, transport: DataTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func command(transcript: String) async throws -> CommandResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("command"))
        request.httpMethod = "POST"
        // Finding an unknown blog's feed is deliberately slow and thorough on
        // the backend (web search, verification); the default 60s would give
        // up on exactly the requests that need the time.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["transcript": transcript])
        return try await send(request)
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

    func shows() async throws -> [Show] {
        try await send(URLRequest(url: baseURL.appendingPathComponent("feeds")))
    }

    func episodes(showID: Int) async throws -> [Episode] {
        let url = baseURL.appendingPathComponent("feeds")
            .appendingPathComponent("\(showID)")
            .appendingPathComponent("episodes")
        return try await send(URLRequest(url: url))
    }

    func searchPodcasts(query: String) async throws -> [PodcastResult] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search/podcasts"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return try await send(URLRequest(url: components.url!))
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
                    ?? "Please open Hearful and sign in.",
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
}
