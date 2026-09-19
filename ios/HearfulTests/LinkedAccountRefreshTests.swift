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
        private var connected = false
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let json: String
            switch request.url!.path {
            case "/auth/google":
                json = #"{"token":"link-test","user":{"id":"current","ai_data_sharing_consented":true}}"#
            case "/me/identities/google":
                connected = true
                json = #"{"providers":["apple","google"]}"#
            case "/me":
                json = "{\"id\":\"current\",\"ai_data_sharing_consented\":\(!connected)}"
            default:
                json = "{}"
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func connectingReloadsPrivacyChoiceAndBothLibraryLists() async {
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
        await auth.signInWithGoogle()
        #expect(storedToken == "link-test")
        #expect(ShortcutScope.current == originalScope)
        #expect(auth.user?.aiDataSharingConsented == true)
        let notifications = Notifications()
        let observers = [Notification.Name.hearfulSubscriptionsChanged, .hearfulSavedChanged].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { _ = notifications.names.insert(name) }
            }
        }
        defer { observers.forEach(center.removeObserver) }
        await auth.linkGoogle()
        #expect(auth.linkedProviders == ["apple", "google"])
        #expect(auth.user?.id == "current")
        #expect(auth.user?.aiDataSharingConsented == false)
        #expect(notifications.names == [.hearfulSubscriptionsChanged, .hearfulSavedChanged])
        #expect(ShortcutScope.current == originalScope)
    }

    private final class Notifications {
        var names: Set<Notification.Name> = []
    }
}
