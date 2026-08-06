import Foundation

enum AppConfiguration {
    /// The simulator shares the Mac's network, so localhost reaches the dev
    /// backend. A real device cannot: it needs the Mac's LAN address, or a
    /// deployed HTTPS backend. Override without rebuilding by setting the
    /// HEARFUL_API_URL environment variable in the scheme.
    static var apiBaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["HEARFUL_API_URL"],
            let url = URL(string: override)
        {
            return url
        }
        return URL(string: "http://localhost:8000")!
    }
}
