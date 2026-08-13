import AuthenticationServices
import Foundation

/// Owns the session: whether we are signed in, signing in with Apple, and
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

    private let api: HearfulAPIProtocol
    private var authRequiredObserver: NSObjectProtocol?
    private var positionReporter: PositionReporter?

    init(api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)) {
        self.api = api
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
        guard KeychainTokenStore.token != nil else {
            state = .signedOut
            return
        }
        state = .signedIn
        Task { _ = try? await api.me() }
    }

    /// Handed the result of the native Sign in with Apple sheet.
    func completeSignIn(result: Result<ASAuthorization, Error>) async {
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
            do {
                let response = try await api.login(appleIdentityToken: identityToken)
                KeychainTokenStore.token = response.token
                state = .signedIn
            } catch let error as APIError {
                signInError = error.spokenResponse
            } catch {
                signInError = APIError.genericSpokenResponse
            }
        }
    }

    func signOut() async {
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

    private func sessionDied() {
        guard state == .signedIn else { return }
        forgetSession()
    }

    private func forgetSession() {
        KeychainTokenStore.clear()
        // The next person to sign in on this phone must not be shown the last
        // person's library out of the cache.
        OfflineCache.shared.clear()
        state = .signedOut
    }
}
