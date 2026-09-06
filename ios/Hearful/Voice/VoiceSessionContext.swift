import Foundation

/// Short-lived context survives closing and reopening the voice sheet. It is
/// scoped to both account and server, and never stores recordings on disk.
@MainActor
final class VoiceSessionContext {
    private static var sessions: [String: VoiceSessionContext] = [:]
    private var lastUsed = ContinuousClock.now
    var pendingRequest: CommandRequest?
    var recentActions: [String] = []
    var conversation = Conversation()
    var undoSpeed: Float?

    static func forAccount(_ account: String?, server: URL) -> VoiceSessionContext {
        sessions = sessions.filter { ContinuousClock.now - $0.value.lastUsed < .seconds(600) }
        let key = server.absoluteString + ":" + (account ?? "anonymous")
        let context = sessions[key] ?? VoiceSessionContext()
        context.lastUsed = .now
        sessions[key] = context
        return context
    }
}
