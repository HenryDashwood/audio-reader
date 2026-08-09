import Foundation

/// Brings back the episode she was listening to when the app was last closed,
/// so the mini player is waiting at the bottom with her position — no
/// scrolling through lists to find where she was.
@MainActor
enum PlaybackRestore {
    static let lastEpisodeKey = "HearfulLastEpisodeID"

    /// Called by the player whenever an episode is loaded.
    static func remember(episodeID: Int, defaults: UserDefaults = .standard) {
        defaults.set(episodeID, forKey: lastEpisodeKey)
    }

    /// Called once when the signed-in UI appears. Fetches the episode fresh
    /// rather than caching it: the payload carries the saved playback
    /// position, which may have moved on another device since last launch.
    static func restore(
        api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
        player: AudioPlayer = .shared,
        defaults: UserDefaults = .standard
    ) async {
        guard player.currentEpisode == nil else { return }
        let id = defaults.integer(forKey: lastEpisodeKey)
        guard id > 0 else { return }
        guard let episode = try? await api.episode(id: id), episode.audioURL != nil else {
            // Deleted episode, dead session, or no network: an empty player
            // is a fine fallback, never an error she has to hear about.
            return
        }
        // She may have started something herself while the fetch was in
        // flight; what she chose wins.
        guard player.currentEpisode == nil else { return }
        player.restore(episode)
    }
}
