import Foundation

/// Shared by microphone input and Siri's already-transcribed requests. A final
/// receipt is mandatory: a disconnected stream is not a successful operation.
@MainActor
enum CommandExecution {
    static func response(
        api: HearfulAPIProtocol, request: CommandRequest, traceparent: String? = nil,
        onDelta: @MainActor (String) -> Void = { _ in }
    ) async throws -> CommandResponse {
        var response: CommandResponse?
        for try await event in api.commandStream(request: request, traceparent: traceparent) {
            try Task.checkCancellation()
            switch event {
            case .assistantDelta(let text): onDelta(text)
            case .result(let result): response = result
            }
        }
        try Task.checkCancellation()
        guard let response else { throw APIError(underlying: "stream ended without a command result") }
        return response
    }

    static func actions(_ response: CommandResponse) -> [CommandResponse] {
        if let actions = response.actions, !actions.isEmpty { return actions }
        return [response]
    }

    /// Server mutations have already committed. Only update the local observers.
    static func broadcast(_ action: CommandResponse, player: AudioPlaying) {
        switch action.action {
        case .subscribed, .unsubscribed:
            ShortcutUndo.clear()
            ShortcutLibrary.shared.invalidate()
            HearfulShortcuts.updateAppShortcutParameters()
            NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
        case .markPlayed, .dismiss, .restore:
            ShortcutUndo.clear()
            if let episode = action.episode, let filing = action.action.filing {
                filing.broadcast(episodeID: episode.id)
                if player.currentEpisode?.id == episode.id {
                    if filing.hidesFromLatest {
                        player.pause()
                    } else if let player = player as? PlaybackCoordinator {
                        player.seek(to: episode.positionSeconds ?? 0)
                    }
                }
            }
        default: break
        }
    }
}
