import Foundation

/// The two kinds of listening deliberately keep separate speeds. Apple speech
/// and recorded voices have very different comfortable ranges, so sharing one
/// preference makes every switch between an article and a podcast require an
/// extra adjustment.
enum PlaybackSpeedPreference {
    enum Content {
        case podcast
        case article

        fileprivate var key: String {
            switch self {
            case .podcast: "HearfulPodcastPlaybackRate"
            case .article: "HearfulArticlePlaybackRate"
            }
        }
    }

    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    static let legacyKey = "HearfulPlaybackRate"

    static func load(_ content: Content, defaults: UserDefaults = .standard) -> Float {
        if defaults.object(forKey: content.key) != nil {
            return clamped(defaults.float(forKey: content.key))
        }

        // Seed both new preferences from the old shared value. This preserves
        // her existing choice through the upgrade, after which each one moves
        // independently.
        if defaults.object(forKey: legacyKey) != nil {
            let migrated = clamped(defaults.float(forKey: legacyKey))
            defaults.set(migrated, forKey: content.key)
            return migrated
        }

        return 1.0
    }

    static func save(
        _ rate: Float,
        for content: Content,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(clamped(rate), forKey: content.key)
    }

    static func clamped(_ rate: Float) -> Float {
        guard rate.isFinite, rate > 0 else { return 1.0 }
        return min(max(rate, 0.5), 3.0)
    }
}
