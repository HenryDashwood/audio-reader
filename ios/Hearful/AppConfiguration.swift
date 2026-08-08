import Foundation

enum AppConfiguration {
    /// The deployed backend. Being the default means a fresh install works
    /// with no configuration — which matters because the person using this
    /// cannot be talked through setting a server address.
    static let defaultBaseURL = URL(string: "https://audio-reader-production.up.railway.app")!
    private static let storageKey = "HearfulAPIBaseURL"

    /// The simulator shares the Mac's network, so localhost reaches the dev
    /// backend. A real device cannot: it needs the Mac's LAN address, or a
    /// deployed HTTPS backend.
    ///
    /// The address is supplied once via the HEARFUL_API_URL environment
    /// variable and then remembered, because launching from Xcode passes it
    /// but tapping the app icon does not — and an app that only works when
    /// launched from a laptop is no use to anyone.
    static var apiBaseURL: URL {
        resolveBaseURL(
            environment: ProcessInfo.processInfo.environment, defaults: .standard)
    }

    static func resolveBaseURL(environment: [String: String], defaults: UserDefaults) -> URL {
        if let override = environment["HEARFUL_API_URL"],
            let url = URL(string: override), url.host != nil
        {
            defaults.set(override, forKey: storageKey)
            return url
        }
        if let remembered = defaults.string(forKey: storageKey),
            let url = URL(string: remembered), url.host != nil
        {
            return url
        }
        return defaultBaseURL
    }
}
