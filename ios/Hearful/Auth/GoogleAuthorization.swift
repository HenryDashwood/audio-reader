import GoogleSignIn
import UIKit

@MainActor
protocol GoogleAuthorizing {
    var isConfigured: Bool { get }
    func identityToken() async throws -> String
    func signOut()
}

@MainActor
struct GoogleAuthorization: GoogleAuthorizing {
    private var clientID: String { Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "" }
    private var serverID: String { Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String ?? "" }

    var isConfigured: Bool {
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return clientID.hasSuffix(".apps.googleusercontent.com") && serverID.hasSuffix(".apps.googleusercontent.com")
            && schemes.contains(clientID.components(separatedBy: ".").reversed().joined(separator: "."))
    }

    func identityToken() async throws -> String {
        guard isConfigured else {
            throw APIError(spokenResponse: "Google sign-in is not available in this build yet.", underlying: "Provider authorization failed", statusCode: 503)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else {
            throw APIError(spokenResponse: "Please try signing in again.", underlying: "Provider authorization failed", statusCode: 0)
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: serverID)
        // Always let the person choose the account, including when linking.
        GIDSignIn.sharedInstance.signOut()
        defer { GIDSignIn.sharedInstance.signOut() }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let token = result.user.idToken?.tokenString else {
                throw APIError(spokenResponse: "Google sign-in did not work. Please try again.", underlying: "Provider authorization failed", statusCode: 0)
            }
            return token
        } catch {
            let failure = error as NSError
            if failure.domain == kGIDSignInErrorDomain && failure.code == GIDSignInError.canceled.rawValue {
                throw CancellationError()
            }
            throw error
        }
    }

    func signOut() { GIDSignIn.sharedInstance.signOut() }
}
