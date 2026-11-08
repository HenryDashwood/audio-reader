import AuthenticationServices
import Foundation
import Testing

@testable import Hearful

@Suite("Refresh the combined account", .serialized)
@MainActor
struct LinkedAccountRefreshTests {
    private struct Google: GoogleAuthorizing {
        let isConfigured = true
        func identityToken() async throws -> String { "verified-google" }
        func signOut() {}
    }

    private actor Transport: DataTransport {
        private(set) var googleLogins = 0
        private var connected = false
        private(set) var links: [String] = []
        let listingStarted = AsyncStream<Void>.makeStream()
        let listingRelease = AsyncStream<Void>.makeStream()
        var listStatus: Int?
        func delayList(status: Int) { listStatus = status }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let json: String
            var status = 200
            switch request.url!.path {
            case "/auth/google":
                googleLogins += 1
                json = #"{"token":"link-test","user":{"id":"current","ai_data_sharing_consented":true,"feature_flags":{"experiment":true}}}"#
            case "/me/identities":
                json = #"{"providers":["apple"]}"#
                if let listStatus {
                    status = listStatus
                    listingStarted.continuation.finish()
                    for await _ in listingRelease.stream {}
                }
            case "/me/identities/google", "/me/identities/apple":
                links.append(request.value(forHTTPHeaderField: "Authorization") ?? "missing")
                connected = true
                json = #"{"providers":["apple","google"]}"#
            case "/me":
                json = "{\"id\":\"current\",\"ai_data_sharing_consented\":\(!connected),\"feature_flags\":{\"experiment\":\(!connected)}}"
            default:
                json = "{}"
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func connectingReloadsPrivacyChoiceAndBothLibraryLists() async throws {
        // This suite runs alongside library/playback tests. Changing the real
        // token would invalidate their in-flight account-scoped requests.
        let originalScope = ShortcutScope.current
        var storedToken: String?
        let api = HearfulAPI(baseURL: URL(string: "https://link.test")!, transport: Transport())
        let center = NotificationCenter()
        let auth = AuthController(
            api: api, google: Google(), notificationCenter: center,
            readToken: { storedToken }, writeToken: { storedToken = $0 })
        auth.bootstrap()
        #expect(auth.state == .signedOut)
        await auth.signInWithGoogle(for: auth.signInAttempt)
        #expect(storedToken == "link-test")
        #expect(ShortcutScope.current == originalScope)
        #expect(auth.user?.aiDataSharingConsented == true)
        #expect(auth.user?.isFeatureEnabled("experiment") == true)
        let notifications = Notifications()
        let observers = [Notification.Name.hearfulSubscriptionsChanged, .hearfulSavedChanged].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { _ = notifications.names.insert(name) }
            }
        }
        defer { observers.forEach(center.removeObserver) }
        let owner = try #require(auth.sessionOwner)
        await auth.linkGoogle(for: owner)
        #expect(auth.linkedProviders == ["apple", "google"])
        #expect(auth.user?.id == "current")
        #expect(auth.user?.aiDataSharingConsented == false)
        #expect(auth.user?.isFeatureEnabled("experiment") == false)
        #expect(notifications.names == [.hearfulSubscriptionsChanged, .hearfulSavedChanged])
        #expect(ShortcutScope.current == originalScope)
    }

    @Test(arguments: ["apple", "google"])
    func delayedProviderCompletionCannotConnectToAnotherSession(provider: String) async throws {
        var token: String? = "first-token"
        let transport = Transport()
        let auth = AuthController(api: HearfulAPI(baseURL: URL(string: "https://link.test")!, transport: transport),
                                  google: Google(), notificationCenter: NotificationCenter(),
                                  readToken: { token }, writeToken: { token = $0 })
        auth.bootstrap()
        let original = try #require(auth.sessionOwner)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let pending = Task {
            await auth.linkIdentity(provider: provider, for: original) {
                started.continuation.finish()
                for await _ in release.stream {}
                return ("first-proof", nil)
            }
        }
        for await _ in started.stream {}
        token = "second-token"
        try #require(!auth.isAuthenticating)
        let current = try #require(auth.sessionOwner)
        let nextStarted = AsyncStream<Void>.makeStream()
        let nextRelease = AsyncStream<Void>.makeStream()
        let next = Task {
            await auth.linkIdentity(provider: provider, for: current) {
                nextStarted.continuation.finish()
                for await _ in nextRelease.stream {}
                return ("second-proof", nil)
            }
        }
        for await _ in nextStarted.stream {}
        release.continuation.finish()
        await pending.value
        await auth.linkIdentity(provider: provider, for: original) {
            Issue.record("An old control started another authorization")
            return ("stale-proof", nil)
        }
        await auth.linkApple(result: .failure(URLError(.timedOut)), for: original)
        #expect(auth.linkingError == nil)
        #expect(await transport.links.isEmpty)
        #expect(auth.isAuthenticating)
        nextRelease.continuation.finish()
        await next.value
        #expect(!auth.isAuthenticating)
        #expect(await transport.links == ["Bearer second-token"])
    }

    @Test(arguments: [200, 503])
    func earlierProviderListCannotUndoAConfirmedLink(status: Int) async throws {
        let transport = Transport()
        let auth = AuthController(api: HearfulAPI(baseURL: URL(string: "https://link.test")!, transport: transport),
                                  google: Google(), notificationCenter: NotificationCenter(), readToken: { "current" })
        auth.bootstrap()
        let owner = try #require(auth.sessionOwner)
        await transport.delayList(status: status)
        let listing = Task { await auth.refreshLinkedProviders() }
        for await _ in transport.listingStarted.stream {}
        await auth.linkGoogle(for: owner)
        transport.listingRelease.continuation.finish()
        await listing.value
        #expect(auth.linkedProviders == ["apple", "google"])
        #expect(auth.linkingError == nil)
        #expect(await transport.links == ["Bearer current"])
    }

    @Test(arguments: [false, true])
    func oldSignInControlsCannotRestartOrReportAnErrorInANewAttempt(afterSignOut: Bool) async throws {
        let transport = Transport()
        var token: String?
        let auth = AuthController(api: HearfulAPI(baseURL: URL(string: "https://link.test")!, transport: transport),
                                  google: Google(), notificationCenter: NotificationCenter(),
                                  readToken: { token }, writeToken: { token = $0 })
        auth.bootstrap()
        let original = auth.signInAttempt
        let staleError = { await auth.completeSignIn(result: .failure(URLError(.timedOut)), for: original) }
        let staleGoogle = { await auth.signInWithGoogle(for: original) }
        if afterSignOut {
            await auth.signInWithGoogle(for: auth.signInAttempt)
            let owner = try #require(auth.sessionOwner)
            await auth.signOut(for: owner)
        } else {
            await auth.completeSignIn(result: .failure(ASAuthorizationError(.canceled)), for: original)
        }
        let sent = await transport.googleLogins
        await staleError()
        #expect(auth.signInError == nil)
        await staleGoogle()
        #expect(await transport.googleLogins == sent)
        #expect(auth.state == .signedOut)
        #expect(token == nil)
        await auth.signInWithGoogle(for: auth.signInAttempt)
        #expect(await transport.googleLogins == sent + 1)
        #expect(auth.state == .signedIn)
    }

    private final class Notifications {
        var names: Set<Notification.Name> = []
    }
}
