import Foundation

/// Retain the receipt after a connection failure so repeating the same typed
/// action recovers its result instead of replacing the original undo snapshot.
@MainActor
final class ShortcutActionExecution {
    static let shared = ShortcutActionExecution()
    private struct Pending {
        let scope: String
        let action: String
        let episodeID: Int?
        let requestID: String
    }
    private var pending: Pending?
    private var executing = false
    private let api: HearfulAPIProtocol
    private let scope: @Sendable () -> String?
    init(
        api: HearfulAPIProtocol = HearfulAPI(),
        scope: @escaping @Sendable () -> String? = { ShortcutScope.current }
    ) {
        self.api = api
        self.scope = scope
    }
    func clear() { pending = nil }
    func run(_ action: String, episodeID: Int?) async throws -> CommandResponse {
        guard let key = scope() else {
            throw ShortcutFailure(message: "Please open Magpie and sign in first.")
        }
        guard !executing else {
            throw ShortcutFailure(message: "Magpie is already updating your library. Please let it finish.")
        }
        executing = true
        defer { executing = false }
        let request: Pending
        if let pending, pending.scope == key, pending.action == action, pending.episodeID == episodeID {
            request = pending
        } else {
            request = Pending(scope: key, action: action, episodeID: episodeID, requestID: UUID().uuidString)
        }
        pending = request
        let response = try await api.libraryAction(action, episodeID: episodeID, requestID: request.requestID)
        try Task.checkCancellation()
        guard scope() == key else { throw CancellationError() }
        pending = nil
        return response
    }
}
