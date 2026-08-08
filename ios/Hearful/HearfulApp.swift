import SwiftUI

@main
struct HearfulApp: App {
    @StateObject private var auth = AuthController()

    var body: some Scene {
        WindowGroup {
            Group {
                switch auth.state {
                case .checking:
                    // Momentary: bootstrap() resolves synchronously from the
                    // Keychain, so this never actually flashes.
                    ProgressView()
                case .signedOut:
                    SignInView(auth: auth)
                case .signedIn:
                    ContentView()
                        .environmentObject(auth)
                }
            }
            .task { auth.bootstrap() }
        }
    }
}
