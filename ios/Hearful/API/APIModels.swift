import Foundation

enum CommandAction: String, Decodable {
    case playEpisode = "play_episode"
    case unknown

    /// The backend can add actions faster than the app gets reinstalled on her
    /// phone. Anything unfamiliar falls back to "unknown", which just speaks
    /// the sentence the backend sent — the right behaviour for outcomes like
    /// "subscribed" that need no action from the app at all.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CommandAction(rawValue: raw) ?? .unknown
    }
}

struct Episode: Decodable, Equatable, Identifiable {
    let id: Int
    let title: String
    let description: String?
    let audioURL: URL?
    let durationSeconds: Int?
    let publishedAt: Date?
    let link: URL?

    enum CodingKeys: String, CodingKey {
        case id, title, description, link
        case audioURL = "audio_url"
        case durationSeconds = "duration_seconds"
        case publishedAt = "published_at"
    }
}

struct CommandResponse: Decodable {
    let action: CommandAction
    let spokenResponse: String
    let episode: Episode?

    enum CodingKeys: String, CodingKey {
        case action, episode
        case spokenResponse = "spoken_response"
    }
}

/// Every failure carries something the app can say out loud. A silent failure
/// or an error tone leaves a blind listener with no idea what happened.
struct APIError: Error {
    let spokenResponse: String
    let underlying: String

    static let genericSpokenResponse =
        "Sorry, something went wrong. Please try again in a moment."

    init(spokenResponse: String = APIError.genericSpokenResponse, underlying: String) {
        self.spokenResponse = spokenResponse
        self.underlying = underlying
    }
}

/// Shape of the backend's 503 body, which carries a sentence meant to be read out.
struct ErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let spokenResponse: String?

        enum CodingKeys: String, CodingKey {
            case spokenResponse = "spoken_response"
        }
    }
    let detail: Detail?
}

/// A podcast the user subscribes to.
struct Show: Decodable, Identifiable, Equatable, Hashable {
    let id: Int
    let title: String
    let description: String?
    let artworkURL: URL?
    let episodeCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, description
        case artworkURL = "image_url"
        case episodeCount = "episode_count"
    }
}
