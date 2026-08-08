import Foundation

protocol HearfulAPIProtocol: Sendable {
    func command(transcript: String) async throws -> CommandResponse
    func episode(id: Int) async throws -> Episode
    func recentEpisodes(limit: Int) async throws -> [Episode]
    func shows() async throws -> [Show]
    func episodes(showID: Int) async throws -> [Episode]
    func login(appleIdentityToken: String) async throws -> AuthResponse
    func logout() async throws
    func me() async throws -> UserInfo
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws
}

extension Notification.Name {
    /// Posted whenever any request comes back 401: the stored session is dead
    /// (revoked, or wiped server-side) and the app should return to sign-in.
    static let hearfulAuthRequired = Notification.Name("hearfulAuthRequired")
}

/// The one thing HearfulAPI needs from the network. Injecting this rather than
/// a URLSession keeps tests free of global stubbing state, which matters
/// because the test runner executes them in parallel.
protocol DataTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DataTransport {}

struct HearfulAPI: HearfulAPIProtocol {
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["transcript": transcript])
        return try await send(request)
    }

    func episode(id: Int) async throws -> Episode {
        let url = baseURL.appendingPathComponent("episodes").appendingPathComponent("\(id)")
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

    func login(appleIdentityToken: String) async throws -> AuthResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/apple"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["identity_token": appleIdentityToken])
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

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter = ISO8601DateFormatter()
}
