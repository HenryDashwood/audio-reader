import Foundation

/// A local-only authentication path for simulator and physical-device
/// development.
///
/// The token is intentionally not a credential: it is a shared development
/// marker accepted only when the backend is explicitly running in its
/// development environment. Ordinary Release/App Store builds compile the
/// lookup out; `make ios-phone-debug` opts its Release build in explicitly so
/// App Intents continue to register on a physical phone.
nonisolated enum DevelopmentAuthentication {
    static func token(baseURL: URL, environment: [String: String]) -> String? {
        #if DEBUG || HEARFUL_LOCAL_DEVICE
            guard let host = baseURL.host?.lowercased(), isLocalHost(host) else { return nil }

            if let configured = environment["HEARFUL_DEVELOPMENT_AUTH_TOKEN"] {
                let token = configured.trimmingCharacters(in: .whitespacesAndNewlines)
                return token.isEmpty ? nil : token
            }
            return "hearful-local-development"
        #else
            return nil
        #endif
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 172 && (16...31).contains(octets[1])
    }
}
