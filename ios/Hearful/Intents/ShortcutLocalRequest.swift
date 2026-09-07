import Foundation

/// Dictated controls take the same local route as microphone controls. They do
/// not need a network connection or permission to send a transcript to a model.
@MainActor
enum ShortcutLocalRequest {
    static func perform(
        _ text: String, player: PlaybackCoordinator = .shared, timer: SleepTimer = .shared,
        foreground: @MainActor (String) async throws -> Void
    ) async throws -> MagpieRequestResult? {
        let result = MagpieRequestResult()
        if ["undo", "undo that", "undo last action"].contains(
            text.lowercased().trimmingCharacters(in: .punctuationCharacters))
        {
            if try ShortcutUndo.undoSpeed(player: player) {
                result.summary = "Playback speed restored."
            } else {
                let response = try await ShortcutActionExecution.shared.run("undo", episodeID: nil)
                guard response.action != .unknown else {
                    throw ShortcutFailure(message: response.spokenResponse)
                }
                CommandExecution.broadcast(response, player: player)
                result.summary = response.spokenResponse
            }
            return result
        }
        if let command = SleepCommand.match(text) {
            switch command {
            case .cancel:
                timer.cancel()
                result.summary = "Sleep timer off."
            case .after(let minutes):
                try ListeningControls.requireItem(player: player)
                timer.start(minutes: minutes)
                result.summary = "I will stop in \(SleepTimer.spokenDuration(minutes: minutes))."
            }
            return result
        }
        guard let command = TransportCommand.match(text) else { return nil }
        if command != .resume { try ListeningControls.requireItem(player: player) }
        switch command {
        case .pause:
            player.pause()
            result.summary = "Paused."
        case .resume:
            let episode = try await ShortcutPlayback.resolve(id: nil, player: player)
            try await ShortcutPlayback.start(episode, player: player) {
                try await foreground("Opening Magpie to continue listening.")
            }
            result.item = EpisodeEntity(episode)
            result.summary = "Continuing \(episode.title)."
        case .skipForward:
            player.skip(by: 30)
            result.summary = "Skipped forward thirty seconds."
        case .skipBack:
            player.skip(by: -15)
            result.summary = "Skipped back fifteen seconds."
        case .seek(let seconds):
            player.skip(by: seconds)
            result.summary = "Listening position changed."
        case .faster, .slower, .normalSpeed, .speed:
            let rate: Float
            switch command {
            case .faster: rate = min(player.playbackRate + 0.25, 3)
            case .slower: rate = max(player.playbackRate - 0.25, 0.5)
            case .normalSpeed: rate = 1
            case .speed(let value): rate = try ListeningControls.rate(Double(value))
            default: return nil
            }
            ShortcutUndo.rememberSpeed(player.playbackRate, applied: rate, mode: player.mode)
            player.setPlaybackRate(rate)
            result.summary = "\(rate) times speed."
        }
        return result
    }
}
