import Foundation

@MainActor
enum ShortcutPlayback {
    /// Search and command results already contain complete, fresh state.
    /// Avoid another network round trip while retaining a loaded player's clock.
    static func chooseFresh(_ episode: Episode, player: PlaybackCoordinator = .shared) -> Episode {
        if let current = player.currentEpisode, current.id == episode.id { return current }
        return episode
    }

    /// A selected item may already be paused in memory at a newer position than
    /// the server. Reusing the loaded player preserves that position exactly.
    static func resolve(
        id: Int?, library: ShortcutLibrary = .shared, player: PlaybackCoordinator = .shared,
        defaults: UserDefaults = .standard
    ) async throws -> Episode {
        if let current = player.currentEpisode, id == nil || id == current.id { return current }
        let selected = id ?? defaults.integer(forKey: PlaybackRestore.lastEpisodeKey)
        guard selected > 0 else {
            throw ShortcutFailure(message: "There is nothing to continue yet. Ask Magpie to play the latest.")
        }
        return try await library.episode(id: selected)
    }

    static func start(
        _ episode: Episode, player: PlaybackCoordinator = .shared,
        foreground: @MainActor () async throws -> Void
    ) async throws {
        guard episode.audioURL != nil || episode.hasText == true else {
            throw ShortcutFailure(message: "That item is not available to listen to.")
        }
        do {
            try AudioSession.configureForPlayback()
            try player.play(episode)
        } catch {
            try await foreground()
            try Task.checkCancellation()
            try player.play(episode)
        }
        do {
            try await withVoiceDeadline(seconds: 12) {
                while true {
                    try Task.checkCancellation()
                    guard player.currentEpisode?.id == episode.id else { throw CancellationError() }
                    if let failure = player.playbackFailure {
                        throw ShortcutFailure(message: failure.message)
                    }
                    if player.mode == .article {
                        if let error = player.article.loadingError { throw ShortcutFailure(message: error) }
                        if player.article.isReadyToPlay { return }
                    } else {
                        if player.audio.isReadyToPlay { return }
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch {
            // A timed-out load must not suddenly start after Siri reports failure.
            if player.currentEpisode?.id == episode.id { player.pause() }
            throw ShortcutFailure.explaining(error)
        }
    }
}
