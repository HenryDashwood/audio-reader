import AuthenticationServices
import Foundation

/// Owns the session: whether we are signed in, linking sign-in methods, and
/// signing out. The gate in HearfulApp switches on `state`.
@MainActor
final class AuthController: ObservableObject {
    enum State: Equatable {
        case checking
        case signedOut
        case signedIn
    }

    @Published private(set) var state: State = .checking {
        didSet {
            // Position reporting exists only while signed in: it must never
            // fire tokenless requests at the backend from the sign-in screen.
            switch state {
            case .signedIn:
                if positionReporter == nil { positionReporter = PositionReporter() }
            case .signedOut, .checking:
                positionReporter = nil
            }
        }
    }
    @Published private(set) var signInError: String?
    /// Nil only while a restored session's /me check is in flight.
    @Published private(set) var user: UserInfo? {
        didSet {
            if let user {
                try? CaptureInbox.shared.configure(.init(userID: user.id, server: AppConfiguration.apiBaseURL))
            }
        }
    }

    @Published private(set) var isAuthenticating = false
    @Published private(set) var linkedProviders: [String]?
    @Published private(set) var linkingError: String?
    var googleIsConfigured: Bool { google.isConfigured }

    private let google: any GoogleAuthorizing
    private var sessionGeneration = 0
    private let api: HearfulAPIProtocol
    private var authRequiredObserver: NSObjectProtocol?
    private var positionReporter: PositionReporter?

    init(api: HearfulAPIProtocol = HearfulAPI(), google: any GoogleAuthorizing = GoogleAuthorization()) {
        self.api = api
        self.google = google
        authRequiredObserver = NotificationCenter.default.addObserver(
            forName: .hearfulAuthRequired, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionDied()
            }
        }
    }

    /// Called once at launch. A stored token is trusted optimistically — she
    /// should not stare at a spinner on aeroplane mode — and validated in the
    /// background; a 401 flips the app back to sign-in via the notification.
    func bootstrap() {
        // An older build used one queue for every account. Never attach those
        // ambiguous events to whichever account happens to open this version.
        TelemetryReporter.removeLegacyQueue()
        guard KeychainTokenStore.token != nil else {
            state = .signedOut
            return
        }
        state = .signedIn
        HearfulShortcuts.updateAppShortcutParameters()
        Task { await refreshUser() }
    }

    func refreshUser() async {
        let generation = sessionGeneration
        do {
            let refreshed = try await api.me()
            guard generation == sessionGeneration, state == .signedIn else { return }
            user = refreshed
        } catch let error as APIError where error.isAuthFailure {
            // The API client has already posted hearfulAuthRequired.
        } catch {
            // Offline is not sign-out. The voice sheet explains that it could
            // not verify the privacy choice and offers another check.
        }
    }

    /// Handed the result of the native Sign in with Apple sheet.
    func completeSignIn(result: Result<ASAuthorization, Error>) async {
        guard !isAuthenticating, state == .signedOut else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let generation = sessionGeneration
        signInError = nil
        switch result {
        case .failure(let error):
            // Cancelling the sheet is not an error worth announcing.
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            signInError = "Sign in did not work. Please try again."
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                signInError = "Sign in did not work. Please try again."
                return
            }
            // Sent so the backend can obtain something to revoke with Apple
            // when she deletes her account. Single-use and short-lived, so it
            // is now or not at all — but not fatal if it is missing: the
            // backend treats it as optional, and sign-in matters more.
            let authorizationCode = credential.authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) }
            do {
                let response = try await api.login(
                    appleIdentityToken: identityToken, authorizationCode: authorizationCode)
                guard generation == sessionGeneration else { return }
                accept(response)
            } catch let error as APIError {
                signInError = error.spokenResponse
            } catch {
                signInError = APIError.genericSpokenResponse
            }
        }
    }

    func signInWithGoogle() async {
        guard !isAuthenticating, state == .signedOut else { return }
        isAuthenticating = true
        signInError = nil
        let generation = sessionGeneration
        defer { isAuthenticating = false }
        do {
            let token = try await google.identityToken()
            guard generation == sessionGeneration else { return }
            let response = try await api.login(googleIdentityToken: token)
            guard generation == sessionGeneration else { return }
            accept(response)
        } catch is CancellationError {
        } catch {
            guard generation == sessionGeneration else { return }
            signInError = (error as? APIError)?.spokenResponse ?? APIError.genericSpokenResponse
        }
    }

    func refreshLinkedProviders() async {
        guard state == .signedIn else { return }
        let generation = sessionGeneration
        linkingError = nil
        do {
            let response = try await api.linkedIdentities()
            guard generation == sessionGeneration else { return }
            linkedProviders = response.providers
        } catch {
            guard generation == sessionGeneration else { return }
            linkingError = (error as? APIError)?.spokenResponse ?? APIError.genericSpokenResponse
        }
    }

    func linkGoogle() async {
        guard !isAuthenticating, state == .signedIn else { return }
        isAuthenticating = true
        linkingError = nil
        let generation = sessionGeneration
        defer { isAuthenticating = false }
        do {
            let token = try await google.identityToken()
            guard generation == sessionGeneration, state == .signedIn else { return }
            let response = try await api.linkIdentity(provider: "google", identityToken: token, authorizationCode: nil)
            guard generation == sessionGeneration else { return }
            linkedProviders = response.providers
        } catch is CancellationError {
        } catch {
            guard generation == sessionGeneration else { return }
            linkingError = (error as? APIError)?.spokenResponse ?? APIError.genericSpokenResponse
        }
    }

    func linkApple(result: Result<ASAuthorization, Error>) async {
        guard !isAuthenticating, state == .signedIn else { return }
        isAuthenticating = true
        linkingError = nil
        let generation = sessionGeneration
        defer { isAuthenticating = false }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let data = credential.identityToken, let token = String(data: data, encoding: .utf8)
            else { throw APIError(spokenResponse: "Apple sign-in did not work. Please try again.", underlying: "Provider authorization failed", statusCode: 0) }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            let response = try await api.linkIdentity(provider: "apple", identityToken: token, authorizationCode: code)
            guard generation == sessionGeneration else { return }
            linkedProviders = response.providers
        } catch let error as ASAuthorizationError where error.code == .canceled {
        } catch {
            guard generation == sessionGeneration else { return }
            linkingError = (error as? APIError)?.spokenResponse ?? APIError.genericSpokenResponse
        }
    }

    private func accept(_ response: AuthResponse) {
        sessionGeneration += 1
        linkedProviders = nil
        KeychainTokenStore.token = response.token
        user = response.user
        state = .signedIn
        ShortcutLibrary.shared.invalidate()
        HearfulShortcuts.updateAppShortcutParameters()
    }

    func signOut() async {
        sessionGeneration += 1
        // Best effort: revoking server-side matters less than forgetting the
        // token locally, and must not block signing out while offline.
        try? await api.logout()
        forgetSession()
    }

    /// Erase the account entirely — App Store guideline 5.1.1(v) requires this
    /// to be reachable from inside the app, and a support email is not that.
    /// Unlike signing out, a failure here matters: pretending it worked would
    /// leave her believing her data is gone when it is not.
    func deleteAccount() async throws {
        try await api.deleteAccount()
        forgetSession()
    }

    func setAIDataSharing(granted: Bool) async throws {
        user = try await api.setAIDataSharing(granted: granted)
        if !granted { TelemetryReporter.clearStoredQueues() }
    }

    private func sessionDied() {
        guard state == .signedIn else { return }
        forgetSession()
    }

    private func forgetSession() {
        sessionGeneration += 1
        google.signOut()
        linkedProviders = nil
        linkingError = nil
        KeychainTokenStore.clear()
        ShortcutLifecycle.resetSession()
        // The next person to sign in on this phone must not be shown the last
        // person's library out of the cache.
        CaptureInbox.shared.signOut()
        SavedLibrary.shared.clear()
        OfflineCache.shared.clear()
        // Events are scoped by account, but removing all queues is the safest
        // boundary on a shared phone and fulfils deletion immediately.
        TelemetryReporter.clearStoredQueues()
        user = nil
        state = .signedOut
    }
}
