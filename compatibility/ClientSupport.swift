import Foundation

// Only device/UI dependencies are replaced. The released HTTP client, JSON
// models, date decoder and request encoders are compiled without modification.
nonisolated enum AppConfiguration {
    static let apiBaseURL = URL(string: "https://compatibility.invalid")!
}
nonisolated enum KeychainTokenStore {
    static let token: String? = "compatibility-test"
}
nonisolated enum EpisodeFiling {
    case played, dismissed, restored
}
