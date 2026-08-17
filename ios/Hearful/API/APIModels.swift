import Foundation

nonisolated enum CommandAction: String, Decodable {
    case playEpisode = "play_episode"
    case setSpeed = "set_speed"
    /// The backend has already filed the episode; the app updates its lists
    /// and, when the episode was the one playing, stops it.
    case markPlayed = "mark_played"
    case dismiss
    case restore
    case unknown

    /// The backend can add actions faster than the app gets reinstalled on her
    /// phone. Anything unfamiliar falls back to "unknown", which just speaks
    /// the sentence the backend sent — the right behaviour for outcomes like
    /// "subscribed" that need no action from the app at all.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CommandAction(rawValue: raw) ?? .unknown
    }

    /// The filing this action reports, for the three that report one.
    var filing: EpisodeFiling? {
        switch self {
        case .markPlayed: .played
        case .dismiss: .dismissed
        case .restore: .restored
        case .playEpisode, .setSpeed, .unknown: nil
        }
    }
}

/// Codable, not just Decodable: the same shape is written back out to the
/// offline cache.
/// Hashable as well, so an episode can be a navigation destination in its own
/// right — which is what opening an article's text on screen is.
nonisolated struct Episode: Codable, Equatable, Hashable, Identifiable {
    let id: Int
    let title: String
    let description: String?
    /// Who wrote it, where the feed says. The byline on the reader's page;
    /// nil for most podcasts, which name a show rather than a person, and for
    /// anything stored before the field existed.
    var author: String?
    let audioURL: URL?
    let durationSeconds: Int?
    let publishedAt: Date?
    let link: URL?
    /// Episode artwork; the backend falls back to the show's artwork, so this
    /// is only nil for feeds with no images at all.
    var imageURL: URL?
    /// This listener's saved playback position; nil when never played.
    /// Optional so payloads from before the field existed still decode.
    var positionSeconds: Double?
    var completed: Bool?
    /// She asked for this one to go without hearing it. Kept apart from
    /// `completed` so a list never claims she listened to something she
    /// skipped — the two look identical from a position alone.
    var dismissed: Bool?
    /// True when the backend can supply article text to read aloud — the cue
    /// that an item with no audio URL is still playable, via text-to-speech.
    var hasText: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, description, author, link, completed, dismissed
        case audioURL = "audio_url"
        case durationSeconds = "duration_seconds"
        case publishedAt = "published_at"
        case imageURL = "image_url"
        case positionSeconds = "position_seconds"
        case hasText = "has_text"
    }

    /// An item the app reads aloud rather than streams.
    var isArticle: Bool { audioURL == nil && hasText == true }
}

/// An article's full text, fetched when it is about to be read aloud — or
/// read on screen.
///
/// Codable rather than Decodable so the reader can keep it: an article she has
/// already opened is then still there with no signal, which is the whole point
/// of the offline cache elsewhere in the app.
nonisolated struct EpisodeText: Codable, Equatable {
    let episodeID: Int
    let title: String
    /// Paragraphs separated by blank lines; the reader chunks on these.
    let text: String
    /// The same article as sanitised HTML, for showing rather than speaking.
    /// Optional twice over: the backend sends null when only plain text could
    /// be recovered, and payloads cached before this field existed have no
    /// key at all.
    var html: String?

    enum CodingKeys: String, CodingKey {
        case title, text, html
        case episodeID = "episode_id"
    }
}

nonisolated struct CommandResponse: Decodable {
    let action: CommandAction
    let spokenResponse: String
    let episode: Episode?
    /// For setSpeed: the playback rate multiplier to apply.
    var speed: Double?
    /// True when the sentence above is a question, and the app should listen
    /// again instead of falling silent and waiting to be tapped.
    ///
    /// The distinction the action cannot make: "Which show did you mean?" and
    /// "You are already subscribed to that" are both `unknown`, and she has to
    /// answer one and not the other. Optional so a payload from before the
    /// field existed still decodes, and reads as "no" — exactly how the app
    /// behaved before any of this.
    var expectsReply: Bool?

    enum CodingKeys: String, CodingKey {
        case action, episode, speed
        case spokenResponse = "spoken_response"
        case expectsReply = "expects_reply"
    }
}

/// Every failure carries something the app can say out loud. A silent failure
/// or an error tone leaves a blind listener with no idea what happened.
nonisolated struct APIError: Error {
    let spokenResponse: String
    let underlying: String
    /// True for a 401: the session is dead, and the caller should suggest
    /// signing in rather than "try again in a moment".
    let isAuthFailure: Bool

    static let genericSpokenResponse =
        "Sorry, something went wrong. Please try again in a moment."

    init(
        spokenResponse: String = APIError.genericSpokenResponse,
        underlying: String,
        isAuthFailure: Bool = false
    ) {
        self.spokenResponse = spokenResponse
        self.underlying = underlying
        self.isAuthFailure = isAuthFailure
    }
}

/// Shape of the backend's 503 body, which carries a sentence meant to be read out.
nonisolated struct ErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let spokenResponse: String?

        enum CodingKeys: String, CodingKey {
            case spokenResponse = "spoken_response"
        }
    }
    let detail: Detail?
}

/// Response to a successful sign-in: our own session token, never Apple's.
nonisolated struct AuthResponse: Decodable {
    let token: String
    let user: UserInfo
}

nonisolated struct UserInfo: Decodable, Equatable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// Body of POST /command.
nonisolated struct CommandRequest: Encodable {
    let transcript: String
    /// What is coming out of the speaker as she talks, so "mark this as
    /// played" has something to refer to.
    var nowPlayingEpisodeID: Int?
    /// What has already been said in this exchange, oldest first, not counting
    /// the transcript above. Empty for a request that starts a subject.
    var turns: [ConversationTurn] = []

    enum CodingKeys: String, CodingKey {
        case transcript, turns
        case nowPlayingEpisodeID = "now_playing_episode_id"
    }
}

/// Body of PUT /episodes/{id}/state. A nil flag is left as it was, so hiding
/// an episode never has to say anything about whether she heard it.
nonisolated struct EpisodeStateUpdate: Encodable {
    var played: Bool?
    var dismissed: Bool?
}

/// Body of PUT /episodes/{id}/position.
nonisolated struct PositionUpdate: Encodable {
    let positionSeconds: Double
    let completed: Bool

    enum CodingKeys: String, CodingKey {
        case completed
        case positionSeconds = "position_seconds"
    }
}

/// A podcast the user subscribes to.
nonisolated struct Show: Codable, Identifiable, Equatable, Hashable {
    let id: Int
    let title: String
    let description: String?
    let artworkURL: URL?
    let episodeCount: Int
    /// The backend has failed to reload this feed repeatedly — it has probably
    /// moved or shut down. Optional so payloads from before the field existed
    /// (including anything already in the offline cache) still decode.
    var isFailing: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, description
        case artworkURL = "image_url"
        case episodeCount = "episode_count"
        case isFailing = "is_failing"
    }
}

/// One show from the public directory; it may not be in our catalog yet, so
/// its identity is its feed URL rather than a database id.
nonisolated struct PodcastResult: Decodable, Identifiable, Equatable, Hashable {
    let title: String
    let feedURL: URL
    let publisher: String?
    let episodeCount: Int?
    let artworkURL: URL?

    var id: URL { feedURL }

    enum CodingKeys: String, CodingKey {
        case title, publisher
        case feedURL = "feed_url"
        case episodeCount = "episode_count"
        case artworkURL = "artwork_url"
    }
}

/// A show's page as seen before (or after) subscribing.
nonisolated struct FeedPreview: Decodable {
    let show: Show
    let episodes: [Episode]
    let subscribed: Bool

    enum CodingKeys: String, CodingKey {
        case show = "feed"
        case episodes, subscribed
    }
}
