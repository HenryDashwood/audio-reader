import AuthenticationServices
import SwiftUI

/// The gate shown until a session exists. One button, nothing to type: the
/// native Sign in with Apple sheet is fully VoiceOver-accessible and works
/// with Face ID alone.
struct SignInView: View {
    @ObservedObject var auth: AuthController
    @Environment(\.colorScheme) private var colorScheme

    /// Wide enough for the button to look deliberate, narrow enough that the
    /// explanatory line does not run the full width of an iPad — a very long
    /// measure is hard to track for anyone reading with magnification.
    private static let contentWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "headphones.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Hearful")
                .font(.largeTitle.bold())
            Text("Sign in so your shows and listening positions follow you.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            if let error = auth.signInError {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task { await auth.completeSignIn(result: result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 56)
            .padding(.horizontal, 32)

            Spacer().frame(height: 48)
        }
        // Centred and capped rather than full-bleed: on an iPad in landscape
        // the button would otherwise be over a metre of pixels wide.
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
    }
}
