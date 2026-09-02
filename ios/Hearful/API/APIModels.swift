import Foundation

nonisolated enum CommandAction: String, Decodable, Sendable {
    case playEpisode = "play_episode"
    case setSpeed = "set_speed"
    /// The backend has already filed the episode; the app updates its lists
    /// and, when the episode was the one playing, stops it.
    case markPlayed = "mark_played"
    case dismiss
    case restore
    case subscribed
    case unsubscribed
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
        case .playEpisode, .setSpeed, .subscribed, .unsubscribed, .unknown: nil
        }
    }
}

/// Codable, not just Decodable: the same shape is written back out to the
/// offline cache.
/// Hashable as well, so an episode can be a navigation destination in its own
/// right — which is what opening an article's text on screen is.
nonisolated struct Episode: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: Int
    let title: String
    let description: String?
    /// Who wrote it, where the feed says. Kept as item authorship rather than
    /// used for the reader's source line, which names the containing feed;
    /// nil for most podcasts and anything stored before the field existed.
    var author: String?
    /// The podcast or publication this item belongs to.
    var feedTitle: String? = nil
    /// Its canonical RSS, Atom or JSON feed. Optional for cached episodes and
    /// older backends; paired with feedTitle to link the byline to the feed's
    /// in-app page.
    var feedURL: URL? = nil
    let audioURL: URL?
    let durationSeconds: Int?
    /// Length of the article's full text, where the backend already knows it.
    /// Optional for audio, teaser-only feeds and payloads cached by older apps.
    var wordCount: Int? = nil
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
        case feedTitle = "feed_title"
        case feedURL = "feed_url"
        case audioURL = "audio_url"
        case durationSeconds = "duration_seconds"
        case wordCount = "word_count"
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
    /// Set only when `text` is the full article. A teaser may still be
    /// returned when page extraction fails, but it is not the article length.
    /// Optional for responses and saved copies from older backends.
    var wordCount: Int? = nil
    /// The same article as sanitised HTML, for showing rather than speaking.
    /// Optional twice over: the backend sends null when only plain text could
    /// be recovered, and payloads cached before this field existed have no
    /// key at all.
    var html: String?

    enum CodingKeys: String, CodingKey {
        case title, text, html
        case episodeID = "episode_id"
        case wordCount = "word_count"
    }
}

nonisolated struct CommandResponse: Decodable, Sendable {
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

nonisolated enum CommandStreamEvent: Sendable {
    case assistantDelta(String)
    case result(CommandResponse)
}

nonisolated struct CommandStreamEnvelope: Decodable {
    let type: String
    let text: String?
    let response: CommandResponse?
    let spokenResponse: String?

    enum CodingKeys: String, CodingKey {
        case type, text, response
        case spokenResponse = "spoken_response"
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
    let aiDataSharingConsented: Bool

    init(id: String, displayName: String?, aiDataSharingConsented: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.aiDataSharingConsented = aiDataSharingConsented
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        // A build may reach an older server briefly during a rolling deploy.
        // Treat a missing consent field as no consent, which is both backwards
        // compatible and the privacy-preserving default.
        aiDataSharingConsented = try container.decodeIfPresent(
            Bool.self,
            forKey: .aiDataSharingConsented
        ) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case aiDataSharingConsented = "ai_data_sharing_consented"
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
    var country: String? = nil

    enum CodingKeys: String, CodingKey {
        case transcript, turns, country
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
nonisolated struct Show: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: Int
    let title: String
    let description: String?
    let artworkURL: URL?
    let episodeCount: Int
    /// Nothing in this feed has audio: every item is text the app reads
    /// aloud. Its items are posts, not episodes, and the app names them so.
    /// Optional so payloads from before the field existed still decode.
    var isArticleFeed: Bool?
    /// The backend has failed to reload this feed repeatedly — it has probably
    /// moved or shut down. Optional so payloads from before the field existed
    /// (including anything already in the offline cache) still decode.
    var isFailing: Bool?
    /// "rss" for anything fetched from the web; "email" for a newsletter that
    /// arrives at her private address. Optional for older payloads and the
    /// offline cache, which both mean an ordinary feed.
    var source: String?
    /// A newsletter that reaches her by way of a forwarding rule in another
    /// inbox. Unsubscribing here cannot stop the emails; the rule can.
    /// Optional for older payloads and the offline cache.
    var forwarded: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, description, source, forwarded
        case artworkURL = "image_url"
        case episodeCount = "episode_count"
        case isArticleFeed = "is_article_feed"
        case isFailing = "is_failing"
    }
}

/// The address she gives a newsletter so its issues reach the app.
nonisolated struct NewsletterAddress: Decodable, Equatable, Sendable {
    let address: String

    /// The part before the @: random letters, which is what has to be typed
    /// or read out correctly.
    var localPart: String { String(address.prefix { $0 != "@" }) }
    var domain: String { String(address.drop { $0 != "@" }.dropFirst()) }

    /// The words the address is made of, when it is made of words. Addresses
    /// are "quiet-heron-otter"; ones minted before that were random letters.
    var words: [String]? {
        let parts = localPart.split(separator: "-").map(String.init)
        guard parts.count > 1, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) else {
            return nil
        }
        return parts
    }

    /// The address as something a voice can say and a listener can write
    /// down: the words one at a time with the hyphens mentioned, or for an
    /// older address the letters one at a time; then the domain as words.
    var spoken: String {
        if let words {
            return "\(words.joined(separator: ", ")), with hyphens between the words, at \(spokenDomain)"
        }
        return "\(spelled(localPart)), at \(spokenDomain)"
    }

    /// Every letter, for when a word was misheard or the listener is writing
    /// it down: "q, u, i, e, t, hyphen, h, e, r, o, n".
    var spelledOut: String {
        let local = localPart.map { $0 == "-" ? "hyphen" : String($0) }.joined(separator: ", ")
        return "\(local), at \(spokenDomain)"
    }

    private var spokenDomain: String { domain.replacingOccurrences(of: ".", with: " dot ") }

    private func spelled(_ text: String) -> String {
        text.map { String($0) }.joined(separator: ", ")
    }
}

/// What came of asking a site for its newsletter.
nonisolated struct NewsletterSignup: Decodable, Equatable, Sendable {
    /// "submitted", "unsupported" or "failed".
    let status: String
    var publication: String?
    var platform: String?
    var address: String?
    /// For "unsupported": account_required, captcha or no_form.
    var reason: String?
    let spokenResponse: String

    var submitted: Bool { status == "submitted" }

    enum CodingKeys: String, CodingKey {
        case status, publication, platform, address, reason
        case spokenResponse = "spoken_response"
    }
}

/// A sender that has written to her address and is waiting for a yes or no.
nonisolated struct PendingNewsletter: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: Int
    let title: String
    let senderAddress: String
    let messageCount: Int
    var latestTitle: String?
    var latestAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title
        case senderAddress = "sender_address"
        case messageCount = "message_count"
        case latestTitle = "latest_title"
        case latestAt = "latest_at"
    }

    var messageCountLabel: String { "\(messageCount) \(messageCount == 1 ? "message" : "messages")" }
}

/// One show from the public directory; it may not be in our catalog yet, so
/// its identity is its feed URL rather than a database id.
nonisolated struct PodcastResult: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let title: String
    let feedURL: URL
    let publisher: String?
    let episodeCount: Int?
    let artworkURL: URL?
    var itunesID: Int? = nil
    var country: String? = nil
    var primaryGenre: String? = nil
    var latestReleaseDate: Date? = nil

    var id: URL { feedURL }

    enum CodingKeys: String, CodingKey {
        case title, publisher, country
        case feedURL = "feed_url"
        case episodeCount = "episode_count"
        case artworkURL = "artwork_url"
        case itunesID = "itunes_id"
        case primaryGenre = "primary_genre"
        case latestReleaseDate = "latest_release_date"
    }
}

/// A verified feed advertised by a website. Discovery does not ingest it;
/// opening the candidate performs the ordinary preview and catalogues only
/// the feed the user actually chose.
nonisolated struct FeedDiscoveryCandidate: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let title: String
    let feedURL: URL
    let description: String?
    let siteURL: URL?
    let format: String
    let itemCount: Int
    let audioItemCount: Int
    let recentItemTitles: [String]
    let source: String
    let isPrimary: Bool

    var id: URL { feedURL }
    var isArticleFeed: Bool { itemCount > 0 && audioItemCount == 0 }

    var podcastResult: PodcastResult {
        PodcastResult(
            title: title,
            feedURL: feedURL,
            publisher: nil,
            episodeCount: itemCount,
            artworkURL: nil)
    }

    enum CodingKeys: String, CodingKey {
        case title, description, format, source
        case feedURL = "feed_url"
        case siteURL = "site_url"
        case itemCount = "item_count"
        case audioItemCount = "audio_item_count"
        case recentItemTitles = "recent_item_titles"
        case isPrimary = "is_primary"
    }
}

nonisolated struct FeedDiscoveryResponse: Decodable, Equatable, Sendable {
    let submittedURL: URL
    let candidates: [FeedDiscoveryCandidate]

    enum CodingKeys: String, CodingKey {
        case candidates
        case submittedURL = "submitted_url"
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
