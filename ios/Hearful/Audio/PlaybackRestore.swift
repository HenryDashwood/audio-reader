import Foundation

/// Brings back the episode she was listening to when the app was last closed,
/// so the mini player is waiting at the bottom with her position — no
/// scrolling through lists to find where she was.
@MainActor
enum PlaybackRestore {
    static let lastEpisodeKey = "HearfulLastEpisodeID"
    private static let snapshotKey = "HearfulLastEpisodeSnapshot"
    private struct Snapshot: Codable {
        let owner: String
        let episode: Episode
    }

    static func remember(_ episode: Episode, defaults: UserDefaults = .standard,
                         scope: String? = ShortcutScope.current) {
        remember(episodeID: episode.id, defaults: defaults)
        guard let scope, let data = try? JSONEncoder().encode(Snapshot(owner: scope, episode: episode)) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func cached(id: Int, defaults: UserDefaults = .standard,
                       scope: String? = ShortcutScope.current) -> Episode? {
        guard let scope, let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.owner == scope, snapshot.episode.id == id else { return nil }
        return snapshot.episode
    }

    /// Called by the player whenever an episode is loaded.
    static func remember(episodeID: Int, defaults: UserDefaults = .standard) {
        defaults.set(episodeID, forKey: lastEpisodeKey)
    }

    /// Called when the player is emptied — she closed it, or the episode
    /// ended. Without this, the next launch would put the same bar back at the
    /// bottom of the screen, which is the thing she was getting rid of.
    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastEpisodeKey)
        defaults.removeObject(forKey: snapshotKey)
    }

    /// Restore local metadata immediately. Explicit playback reconciles the
    /// article bookmark; restoring a paused player must not require a server.
    static func restore(
        api: HearfulAPIProtocol = HearfulAPI(),
        player: PlaybackCoordinator = .shared,
        defaults: UserDefaults = .standard,
        scope: String? = ShortcutScope.current
    ) async {
        guard player.currentEpisode == nil else { return }
        let id = defaults.integer(forKey: lastEpisodeKey)
        guard id > 0 else { return }
        if let local = cached(id: id, defaults: defaults, scope: scope),
           local.audioURL != nil || local.hasText == true {
            player.restore(scope.map { PodcastProgressJournal.shared.overlay(local, owner: $0) } ?? local)
            return
        }
        guard let episode = try? await api.episode(id: id),
            episode.audioURL != nil || episode.hasText == true
        else {
            // Deleted episode, dead session, or no network: an empty player
            // is a fine fallback, never an error she has to hear about.
            return
        }
        // She may have started something herself while the fetch was in
        // flight; what she chose wins.
        guard player.currentEpisode == nil, ShortcutScope.current == scope else { return }
        player.restore(episode)
    }
}
