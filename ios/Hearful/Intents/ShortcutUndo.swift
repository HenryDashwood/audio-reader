import Foundation

@MainActor
enum ShortcutUndo {
    private struct SpeedChange {
        let scope: String?
        let before: Float
        let after: Float
        let mode: PlaybackCoordinator.Mode
        let date: Date
    }
    private static var speed: SpeedChange?
    static func clear() {
        speed = nil
        VoiceSessionContext.clearUndoSpeeds()
    }
    static func rememberSpeed(_ before: Float, applied: Float, mode: PlaybackCoordinator.Mode) {
        VoiceSessionContext.clearUndoSpeeds()
        speed = SpeedChange(
            scope: ShortcutScope.current, before: before, after: applied, mode: mode, date: Date())
    }
    static func undoSpeed(player: PlaybackCoordinator = .shared) throws -> Bool {
        guard let change = speed else { return false }
        speed = nil
        guard change.scope == ShortcutScope.current, Date().timeIntervalSince(change.date) < 600 else {
            return false
        }
        let current = change.mode == .audio ? player.podcastPlaybackRate : player.articlePlaybackRate
        guard current == change.after else {
            throw ShortcutFailure(message: "Playback speed has changed since then. I left it as it is.")
        }
        if change.mode == .audio {
            player.setPodcastPlaybackRate(change.before)
        } else {
            player.setArticlePlaybackRate(change.before)
        }
        return true
    }
}
