import SwiftUI

/// Import and export keep a fixed account and server for each operation, but
/// Keychain IPC must never run while SwiftUI constructs a navigation destination.
nonisolated struct SubscriptionSession: Sendable {
    let token: String?
    let server: URL

    @concurrent static func capture(
        readToken: @Sendable () -> String? = { KeychainTokenStore.token },
        server: URL = AppConfiguration.apiBaseURL
    ) async -> SubscriptionSession {
        SubscriptionSession(token: readToken(), server: server)
    }

    @concurrent func isCurrent(
        readToken: @Sendable () -> String? = { KeychainTokenStore.token },
        server: URL = AppConfiguration.apiBaseURL
    ) async -> Bool {
        readToken() == token && server == self.server
    }
}

struct SubscriptionSessionView<Content: View>: View {
    let title: String
    let loadSession: @Sendable () async -> SubscriptionSession
    @ViewBuilder let content: (SubscriptionSession) -> Content
    @State private var session: SubscriptionSession?

    var body: some View {
        Group {
            if let session { content(session) }
            else { ProgressView("Loading account…").navigationTitle(title) }
        }
        .task {
            guard session == nil else { return }
            let captured = await loadSession()
            guard !Task.isCancelled else { return }
            session = captured
        }
    }
}
