import Foundation
import OSLog

// nonisolated: the cache is called from the main actor and from background
// tasks alike, and Logger is documented thread-safe.
private nonisolated let log = Logger(subsystem: "com.henrydashwood.hearful", category: "cache")

/// The last successful answer to each list request, kept on disk.
///
/// Every screen in this app is a live request, so a weak signal used to turn
/// the whole library into "Could not load what you follow" — an apology, with no
/// way forward, for someone who cannot check whether the Wi-Fi is the problem.
/// Holding the previous answer means the shows are still there, still
/// playable if they are downloaded, and the failure is a note rather than a
/// wall.
///
/// Not a substitute for downloads: episode audio still needs the network.
/// What this fixes is the app forgetting everything it already knew.
nonisolated struct OfflineCache {
    static let shared = OfflineCache()

    enum Key: Equatable {
        case savedArticles
        case articleVersion(episodeID: Int, contentID: Int)
        case shows
        case recentEpisodes
        case episodes(showID: Int)
        /// One article's text. Unlike episode audio, an article is small
        /// enough that having read it once is enough to keep it.
        case articleText(episodeID: Int)

        var filename: String {
            switch self {
            case .savedArticles: "saved-articles.json"
            case .articleVersion(let episodeID, let contentID): "article-\(episodeID)-version-\(contentID).json"
            case .shows: "shows.json"
            case .recentEpisodes: "recent-episodes.json"
            case .episodes(let showID): "show-\(showID)-episodes.json"
            case .articleText(let episodeID): "article-\(episodeID).json"
            }
        }
    }

    let directory: URL

    /// Application Support rather than Caches: the system may empty Caches
    /// under disk pressure, and the one moment this has to work is the moment
    /// there is no network to refill it from.
    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? URL.applicationSupportDirectory.appending(path: "OfflineCache", directoryHint: .isDirectory)
    }

    @discardableResult
    func save(_ value: some Encodable, for key: Key) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(value).write(to: file(for: key), options: .atomic)
            return true
        } catch {
            // A cache that cannot be written is not a reason to fail the
            // request that just succeeded.
            log.notice("could not cache \(key.filename): \(error.localizedDescription)")
            return false
        }
    }

    /// Exact versions may also exist in the legacy unversioned slot. An
    /// unknown selection uses only the last resolved copy, never a guessed
    /// version from a directory listing.
    func article(episodeID: Int, contentID: Int? = nil) -> EpisodeText? {
        let selectedID = contentID ?? load([Episode].self, for: .savedArticles)?.first { $0.id == episodeID }?.contentID
        let key: Key = selectedID.map { .articleVersion(episodeID: episodeID, contentID: $0) }
            ?? .articleText(episodeID: episodeID)
        func valid(_ value: EpisodeText) -> Bool {
            value.episodeID == episodeID && (selectedID == nil || value.contentID == selectedID)
                && !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let value = load(EpisodeText.self, for: key), valid(value) { return value }
        if key != .articleText(episodeID: episodeID),
           let legacy = load(EpisodeText.self, for: .articleText(episodeID: episodeID)), valid(legacy) { return legacy }
        return nil
    }

    func cachedEpisode(id: Int) -> Episode? {
        let lists: [Key] = [.savedArticles, .recentEpisodes]
            + (load([Show].self, for: .shows) ?? []).map { .episodes(showID: $0.id) }
        return lists.lazy.compactMap { load([Episode].self, for: $0)?.first { $0.id == id } }.first
    }

    /// Keep the canonical version and last resolved selection together for
    /// readers opened from older list metadata. Progress-only acknowledgements
    /// must not change the currently selected article.
    @discardableResult
    func saveArticle(_ article: EpisodeText, select: Bool = true) -> Bool {
        guard article.episodeID > 0, article.contentID == nil || article.contentID! > 0,
              !article.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let version = article.contentID {
            guard save(article, for: .articleVersion(episodeID: article.episodeID, contentID: version)) else { return false }
        }
        if select || article.contentID == nil {
            guard save(article, for: .articleText(episodeID: article.episodeID)) else { return false }
        } else if load(EpisodeText.self, for: .articleText(episodeID: article.episodeID))?.contentID == article.contentID {
            _ = save(article, for: .articleText(episodeID: article.episodeID))
        }
        NotificationCenter.default.post(name: .hearfulArticleCached, object: article.episodeID)
        return true
    }

    func load<T: Decodable>(_ type: T.Type, for key: Key) -> T? {
        guard let data = try? Data(contentsOf: file(for: key)) else { return nil }
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            // Written by an older version whose shape has since changed.
            log.notice("discarding unreadable cache \(key.filename)")
            try? FileManager.default.removeItem(at: file(for: key))
            return nil
        }
    }

    /// Everything, for signing out: the next person to sign in on this phone
    /// must not be shown the last person's library.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(for key: Key) -> URL {
        directory.appending(path: key.filename)
    }

    // Both ends are ours, so a plain ISO 8601 date round-trips — unlike the
    // API decoder, which has to tolerate whatever the feed provided.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
