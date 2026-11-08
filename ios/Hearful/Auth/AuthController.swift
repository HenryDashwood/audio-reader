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
                positionReporter?.invalidate()
                positionReporter = nil
            }
        }
    }
    @Published private(set) var signInError: String?
    /// Nil only while a restored session's /me check is in flight.
    @Published private(set) var user: UserInfo? {
        didSet {
            if let user {
                let account = CaptureInbox.Account(userID: user.id, server: AppConfiguration.apiBaseURL)
                if !TestEnvironment.isRunningTests, let token = readToken() {
                    do {
                        let session = CaptureSessionStore.Session(account: account, token: token)
                        try CaptureSessionStore.write(session)
                        Task { _ = try? await PlusStore.shared.perform(session: session, configureOnly: true) }
                    }
                    catch { CaptureSessionStore.clear() }
                }
                try? CaptureInbox.shared.configure(account)
            }
        }
    }

    @Published private(set) var signInAttempt = UUID()
    @Published private var signingIn: UUID?
    @Published private var linkingOwner: SessionOwner?
    var isAuthenticating: Bool { signingIn == signInAttempt || (linkingOwner != nil && linkingOwner == sessionOwner) }
    @Published private(set) var linkedProviders: [String]?
    @Published private(set) var linkingError: String?
    var googleIsConfigured: Bool { google.isConfigured }

    private let google: any GoogleAuthorizing
    private var sessionGeneration = 0
    private var userRevision = 0
    private var sharingRequest: UUID?
    private var providersRevision = 0
    private let api: HearfulAPIProtocol
    private let notificationCenter: NotificationCenter
    private let readToken: () -> String?
    private let writeToken: (String?) -> Void
    private var authRequiredObserver: NSObjectProtocol?
    private var positionReporter: PositionReporter?

    init(api: HearfulAPIProtocol = HearfulAPI(), google: any GoogleAuthorizing = GoogleAuthorization(),
         notificationCenter: NotificationCenter = .default,
         readToken: @escaping () -> String? = { KeychainTokenStore.token },
         writeToken: @escaping (String?) -> Void = { KeychainTokenStore.token = $0 }) {
        self.api = api
        self.google = google
        self.notificationCenter = notificationCenter
        self.readToken = readToken
        self.writeToken = writeToken
        authRequiredObserver = notificationCenter.addObserver(
            forName: .hearfulAuthRequired, object: nil, queue: .main
        ) { [weak self] note in
            guard let rejected = note.object as? RejectedSession else { return }
            MainActor.assumeIsolated {
                self?.sessionDied(rejected)
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
        guard readToken() != nil else {
            if !TestEnvironment.isRunningTests { CaptureSessionStore.clear() }
            state = .signedOut
            return
        }
        state = .signedIn
        OfflineLibraryActions.shared.retry()
        HearfulShortcuts.updateAppShortcutParameters()
        Task { await refreshUser() }
    }

    func refreshUser() async {
        let generation = sessionGeneration
        let token = readToken()
        userRevision += 1
        let revision = userRevision
        do {
            let refreshed = try await api.me()
            guard generation == sessionGeneration, revision == userRevision, token == readToken(), state == .signedIn else { return }
            user = refreshed
        } catch let error as APIError where error.isAuthFailure {
            // The API client has already posted hearfulAuthRequired.
        } catch {
            // Offline is not sign-out. The voice sheet explains that it could
            // not verify the privacy choice and offers another check.
        }
    }

    private func canFinishSignIn(_ attempt: UUID) -> Bool {
        state == .signedOut && attempt == signInAttempt
    }

    private func finishSignIn(_ attempt: UUID) {
        if signingIn == attempt { signingIn = nil }
        if signInAttempt == attempt { signInAttempt = UUID() }
    }

    /// The result belongs to the button that opened the native authorization sheet.
    func completeSignIn(result: Result<ASAuthorization, Error>, for attempt: UUID) async {
        guard canFinishSignIn(attempt), !isAuthenticating else { return }
        signingIn = attempt
        defer { finishSignIn(attempt) }
        signInError = nil
        switch result {
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled { return }
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
            // Apple supplies a single-use code for revocation when the account is deleted.
            let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            do {
                let response = try await api.login(appleIdentityToken: identityToken, authorizationCode: authorizationCode)
                guard canFinishSignIn(attempt) else { return }
                accept(response)
            } catch {
                guard canFinishSignIn(attempt) else { return }
                signInError = (error as? APIError)?.spokenResponse ?? APIError.genericSpokenResponse
            }
        }
    }

    func signInWithGoogle(for attempt: UUID) async {
        guard canFinishSignIn(attempt), !isAuthenticating else { return }
        signingIn = attempt
        defer { finishSignIn(attempt) }
        signInError = nil
        do {
            let token = try await google.identityToken()
            guard canFinishSignIn(attempt) else { return }
            let response = try await api.login(googleIdentityToken: token)
            guard canFinishSignIn(attempt) else { return }
            accept(response)
        } catch is CancellationError {
        } catch {
            guard canFinishSignIn(attempt) else { return }
            signInError = (error as? APIError)?.spokenResponse ?? APIError.genericSpokenResponse
        }
    }

    func refreshLinkedProviders() async {
        guard let owner = sessionOwner else { return }
        let session = HearfulAPI.RequestSession(token: readToken())
        providersRevision += 1
        let revision = providersRevision
        linkingError = nil
        do {
            let response = try await session.perform { try await api.linkedIdentities() }
            guard owner == sessionOwner, revision == providersRevision else { return }
            linkedProviders = response.providers
        } catch {
            guard owner == sessionOwner, revision == providersRevision else { return }
            linkingError = (error as? APIError)?.spokenResponse ?? APIError.genericSpokenResponse
        }
    }

    func linkGoogle(for owner: SessionOwner) async {
        await linkIdentity(provider: "google", for: owner) {
            (try await self.google.identityToken(), nil)
        }
    }

    func linkApple(result: Result<ASAuthorization, Error>, for owner: SessionOwner) async {
        await linkIdentity(provider: "apple", for: owner) {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let data = credential.identityToken, let token = String(data: data, encoding: .utf8)
            else { throw APIError(spokenResponse: "Apple sign-in did not work. Please try again.", underlying: "Provider authorization failed", statusCode: 0) }
            return (token, credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) })
        }
    }

    func linkIdentity(provider: String, for owner: SessionOwner,
                      credentials: () async throws -> (token: String, code: String?)) async {
        guard !isAuthenticating, owner == sessionOwner else { return }
        let session = HearfulAPI.RequestSession(token: readToken())
        linkingOwner = owner
        linkingError = nil
        defer { if linkingOwner == owner { linkingOwner = nil } }
        do {
            let credential = try await credentials()
            guard owner == sessionOwner else { return }
            let response = try await session.perform {
                try await api.linkIdentity(provider: provider, identityToken: credential.token, authorizationCode: credential.code)
            }
            guard owner == sessionOwner else { return }
            providersRevision += 1
            linkedProviders = response.providers
            linkingError = nil
            await session.perform { await linkedAccountChanged(owner: owner) }
        } catch is CancellationError {
        } catch let error as ASAuthorizationError where error.code == .canceled {
        } catch {
            guard owner == sessionOwner else { return }
            linkingError = (error as? APIError)?.spokenResponse ?? APIError.genericSpokenResponse
        }
    }

    private func linkedAccountChanged(owner: SessionOwner) async {
        await refreshUser()
        guard owner == sessionOwner else { return }
        ShortcutLibrary.shared.invalidate()
        HearfulShortcuts.updateAppShortcutParameters()
        notificationCenter.post(name: .hearfulSubscriptionsChanged, object: nil)
        notificationCenter.post(name: .hearfulSavedChanged, object: nil)
    }

    private func accept(_ response: AuthResponse) {
        sessionGeneration += 1
        sharingRequest = nil
        linkedProviders = nil
        positionReporter?.invalidate()
        positionReporter = nil
        writeToken(response.token)
        user = response.user
        state = .signedIn
        ShortcutLibrary.shared.invalidate()
        HearfulShortcuts.updateAppShortcutParameters()
    }

    func signOut(for owner: SessionOwner) async {
        let session = HearfulAPI.RequestSession(token: readToken())
        guard state == .signedIn, owner.generation == sessionGeneration, owner.scope == session.scope else { return }
        sessionGeneration += 1
        let generation = sessionGeneration
        // Best effort: revoking server-side matters less than forgetting the
        // token locally, and must not block signing out while offline.
        try? await session.perform { try await api.logout() }
        guard generation == sessionGeneration, session.scope == sessionOwner?.scope else { return }
        forgetSession()
    }

    struct SessionOwner: Hashable, Identifiable {
        var id: Self { self }
        fileprivate let scope: String
        fileprivate let generation: Int
    }

    var sessionOwner: SessionOwner? {
        guard state == .signedIn, let scope = HearfulAPI.RequestSession(token: readToken()).scope else { return nil }
        return SessionOwner(scope: scope, generation: sessionGeneration)
    }

    /// Erase the account entirely — App Store guideline 5.1.1(v) requires this
    /// to be reachable from inside the app, and a support email is not that.
    /// Unlike signing out, a failure here matters: pretending it worked would
    /// leave her believing her data is gone when it is not.
    func deleteAccount(confirmedFor owner: SessionOwner) async throws {
        let session = HearfulAPI.RequestSession(token: readToken())
        guard state == .signedIn, owner.generation == sessionGeneration, owner.scope == session.scope else {
            throw CancellationError()
        }
        do { try await session.perform { try await api.deleteAccount() } }
        catch {
            guard owner == sessionOwner else { throw CancellationError() }
            throw error
        }
        guard owner == sessionOwner else { throw CancellationError() }
        forgetSession()
    }

    func setAIDataSharing(granted: Bool, confirmedFor owner: SessionOwner) async throws {
        guard owner == sessionOwner, sharingRequest == nil else { throw CancellationError() }
        let session = HearfulAPI.RequestSession(token: readToken())
        let request = UUID()
        sharingRequest = request
        defer { if sharingRequest == request { sharingRequest = nil } }
        let updated: UserInfo
        do { updated = try await session.perform { try await api.setAIDataSharing(granted: granted) } }
        catch {
            guard owner == sessionOwner else { throw CancellationError() }
            throw error
        }
        guard owner == sessionOwner,
              user == nil || user?.id == updated.id else { throw CancellationError() }
        userRevision += 1
        user = updated
        if !granted { TelemetryReporter.clearStoredQueues() }
    }

    private func sessionDied(_ rejected: RejectedSession) {
        guard state == .signedIn, rejected.matches(token: readToken(), server: AppConfiguration.apiBaseURL) else { return }
        forgetSession()
    }

    private func forgetSession() {
        signInAttempt = UUID()
        signInError = nil
        sessionGeneration += 1
        sharingRequest = nil
        positionReporter?.invalidate()
        positionReporter = nil
        try? FileArticleProgressStorage.shared.clearAll()
        try? FilePodcastProgressStorage.shared.clearAll()
        OfflineSyncStatus.shared.message = nil
        OfflineLibraryActions.shared.clear()
        google.signOut()
        linkedProviders = nil
        linkingError = nil
        writeToken(nil)
        CaptureSessionStore.clear()
        ShortcutLifecycle.resetSession()
        // The next person to sign in on this phone must not be shown the last
        // person's library out of the cache.
        CaptureInbox.shared.signOut()
        SavedLibrary.shared.clear()
        OfflineCache.shared.clear()
        EpisodeDownloads.shared.clear()
        // Events are scoped by account, but removing all queues is the safest
        // boundary on a shared phone and fulfils deletion immediately.
        TelemetryReporter.clearStoredQueues()
        user = nil
        state = .signedOut
    }
}
