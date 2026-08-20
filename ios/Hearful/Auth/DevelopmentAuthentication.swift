import Foundation

/// A local-only authentication path for simulator development.
///
/// The token is intentionally not a credential: it is a shared development
/// marker accepted only when the backend is explicitly running in its
/// development environment. The entire lookup is compiled out of Release.
nonisolated enum DevelopmentAuthentication {
    static func token(baseURL: URL, environment: [String: String]) -> String? {
        #if DEBUG
            guard let host = baseURL.host?.lowercased(),
                ["localhost", "127.0.0.1", "::1"].contains(host)
            else { return nil }

            if let configured = environment["HEARFUL_DEVELOPMENT_AUTH_TOKEN"] {
                let token = configured.trimmingCharacters(in: .whitespacesAndNewlines)
                return token.isEmpty ? nil : token
            }
            return "hearful-local-development"
        #else
            return nil
        #endif
    }
}
