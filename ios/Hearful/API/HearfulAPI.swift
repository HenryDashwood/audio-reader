import Foundation

protocol HearfulAPIProtocol: Sendable {
    func command(transcript: String) async throws -> CommandResponse
    func episode(id: Int) async throws -> Episode
    func recentEpisodes(limit: Int) async throws -> [Episode]
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

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
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
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(
                // Prefer the sentence the backend wrote; fall back to a generic one.
                spokenResponse: Self.spokenResponse(from: data) ?? APIError.genericSpokenResponse,
                underlying: "HTTP \(http.statusCode)")
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(underlying: "could not decode response: \(error)")
        }
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
