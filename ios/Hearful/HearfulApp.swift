import SwiftUI

@main
struct HearfulApp: App {
    @StateObject private var auth = AuthController()
    /// Subscribed for the life of the app. iOS delivers crash and hang reports
    /// in a daily batch at a moment of its choosing, so there is no later point
    /// at which registering would still catch them.
    private let diagnostics = DiagnosticsReporter(
        api: HearfulAPI(baseURL: AppConfiguration.apiBaseURL))

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
            .task {
                auth.bootstrap()
                #if canImport(KokoroSwift) && !targetEnvironment(simulator)
                    KokoroBenchmark.runIfRequested()
                #endif
            }
        }
    }
}
