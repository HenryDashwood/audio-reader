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
        let previousToken = KeychainTokenStore.token
        KeychainTokenStore.clear()
        defer { KeychainTokenStore.token = previousToken }
        let api = HearfulAPI(baseURL: URL(string: "https://link.test")!, transport: Transport())
        let center = NotificationCenter()
        let auth = AuthController(api: api, google: Google(), notificationCenter: center)
        auth.bootstrap()
        await auth.signInWithGoogle()
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
    }

    private final class Notifications {
        var names: Set<Notification.Name> = []
    }
}
