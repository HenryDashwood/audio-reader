import Foundation

/// nonisolated: read by App Intents off the main actor; UserDefaults and
/// ProcessInfo are both thread-safe.
nonisolated enum AppConfiguration {
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

    static var privacyURL: URL {
        apiBaseURL.appendingPathComponent("privacy")
    }

    static let supportURL = URL(string: "mailto:hcndashwood@gmail.com")!

    static func resolveBaseURL(environment: [String: String], defaults: UserDefaults) -> URL {
        if let override = environment["HEARFUL_API_URL"],
            let url = URL(string: override), url.host != nil
        {
            // Launching a device build with the ordinary production address
            // is not an override. Clear any older laptop address and keep the
            // Settings screen from claiming production is a test server.
            if url == defaultBaseURL {
                defaults.removeObject(forKey: storageKey)
                return defaultBaseURL
            }
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

    /// Whether a remembered address is in force, and what it is.
    ///
    /// Worth being able to see: the address is remembered precisely so that it
    /// survives launching from the home screen, which also means one debug
    /// launch pointed at a laptop follows the app around forever. On her phone
    /// that looks like an app that has simply stopped working.
    static func rememberedOverride(defaults: UserDefaults = .standard) -> String? {
        guard let remembered = defaults.string(forKey: storageKey) else { return nil }
        if URL(string: remembered) == defaultBaseURL {
            defaults.removeObject(forKey: storageKey)
            return nil
        }
        return remembered
    }

    /// Forget it and go back to the deployed backend.
    static func clearRememberedOverride(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
