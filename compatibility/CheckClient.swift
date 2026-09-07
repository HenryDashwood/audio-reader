import Foundation

struct Exchange: Decodable, Sendable {
    let name: String
    let method: String
    let path: String
    let status: Int
    let response: String
}

struct ContractFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ContractFailure(description: message) }
}

// Immutable per-request transport; no shared mutable state across async calls.
final class ReplayTransport: DataTransport, Sendable {
    let exchange: Exchange
    let expectedBody: Data?

    init(_ exchange: Exchange, expectedBody: Data?) {
        self.exchange = exchange
        self.expectedBody = expectedBody
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        try require(request.httpMethod == exchange.method, "HTTP method changed: \(exchange.name)")
        try require(path == exchange.path, "Path changed: \(path), expected \(exchange.path)")
        if let expectedBody {
            let expected = try JSONSerialization.jsonObject(with: expectedBody) as! NSDictionary
            var actual = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
            // The release reads the device's region, while backend fixtures are locale independent.
            actual.removeValue(forKey: "country")
            try require(NSDictionary(dictionary: actual).isEqual(to: expected as! [AnyHashable: Any]),
                        "Request JSON changed: \(exchange.name)")
        } else {
            try require(request.httpBody == nil, "Unexpected request body: \(exchange.name)")
        }
        return (Data(exchange.response.utf8), HTTPURLResponse(
            url: url, statusCode: exchange.status, httpVersion: nil, headerFields: nil)!)
    }
}

@main
struct CheckClient {
    static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let exchanges = try JSONDecoder().decode([Exchange].self, from: data)
        let raw = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for (index, exchange) in exchanges.enumerated() {
            let body = raw[index]["request"]
            let expectedBody = body is NSNull ? nil : try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let api = HearfulAPI(baseURL: AppConfiguration.apiBaseURL,
                                 transport: ReplayTransport(exchange, expectedBody: expectedBody))
            switch exchange.name {
            case "stream":
                var request = URLRequest(url: AppConfiguration.apiBaseURL.appendingPathComponent("command/stream"))
                request.httpMethod = "POST"
                request.httpBody = try JSONEncoder().encode(CommandRequest(transcript: "which show", nowPlayingEpisodeID: nil))
                let (streamData, _) = try await ReplayTransport(exchange, expectedBody: expectedBody).data(for: request)
                let envelopes = try String(decoding: streamData, as: UTF8.self).split(separator: "\n").map {
                    try JSONDecoder().decode(CommandStreamEnvelope.self, from: Data($0.utf8))
                }
                let results = envelopes.filter { $0.type == "result" }
                try require(results.count == 1, "Stream must contain exactly one final result")
                try require(results[0].response?.expectsReply == true, "Streamed question lost")
                try require(envelopes.contains { $0.type == "assistant_delta" && $0.text != nil }, "Streamed speech lost")
            case "me":
                try require(try await api.me().aiDataSharingConsented, "Consent lost")
            case "feeds":
                try require(try await api.shows().first?.id == 101, "Subscription lost")
            case "episodes":
                try require(try await api.episodes(showID: 101).count == 2, "Feed episodes lost")
            case "recent":
                try require(try await api.recentEpisodes().count == 2, "Latest episodes lost")
            case "episode":
                let episode = try await api.episode(id: 201)
                try require(episode.audioURL?.absoluteString == "https://cdn.example.com/201.mp3", "Audio URL lost")
                try require(episode.publishedAt != nil, "Release cannot decode date")
            case "text":
                try require(try await api.articleText(episodeID: 202).text == "An article available offline.", "Article text lost")
            case "search":
                try require(try await api.searchLibraryEpisodes(query: "Vienna").first?.id == 201, "Search result lost")
            case "position":
                try await api.reportPosition(episodeID: 201, seconds: 45.5, completed: false, durationSeconds: 2700)
            case "savedPosition":
                try require(try await api.episode(id: 201).positionSeconds == 45.5, "Position lost")
            case "dismiss":
                try await api.setEpisodeState(episodeID: 201, played: nil, dismissed: true)
            case "dismissed":
                try require(try await api.episode(id: 201).dismissed == true, "Dismissal lost")
            case "restore":
                try await api.setEpisodeState(episodeID: 201, played: false, dismissed: false)
            case "command":
                let result = try await api.command(transcript: "play Vienna")
                try require(result.action == .playEpisode && result.episode?.id == 201, "Play action lost")
            case "speed":
                let result = try await api.command(transcript: "speed up")
                try require(result.action == .setSpeed && result.speed == 1.5, "Speed action lost")
            case "speakableError":
                do {
                    _ = try await api.command(transcript: "play something")
                    throw ContractFailure(description: "Expected a speakable error")
                } catch let error as APIError {
                    try require(error.underlying == "HTTP 503" && !error.spokenResponse.isEmpty, "Error contract lost")
                }
            case "newsletterAddress":
                try require(try await api.newsletterAddress().domain == "inbox.example.com", "Newsletter address lost")
            case "pendingNewsletters":
                _ = try await api.pendingNewsletters()
            case "consent":
                try require(try await api.setAIDataSharing(granted: true).aiDataSharingConsented, "Consent update lost")
            case "clearLatest": try await api.clearLatest()
            case "unsubscribe": try await api.unsubscribe(showID: 101)
            default: throw ContractFailure(description: "Untested exchange: \(exchange.name)")
            }
            print("PASS v1.4.1: \(exchange.name)")
        }
        try require(exchanges.count >= 20, "Missing contract exchanges")
    }
}
