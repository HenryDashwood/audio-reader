import AuthenticationServices
import SwiftUI

/// The gate shown until a session exists. One button, nothing to type: the
/// native Sign in with Apple sheet is fully VoiceOver-accessible and works
/// with Face ID alone.
struct SignInView: View {
    @ObservedObject var auth: AuthController
    @Environment(\.colorScheme) private var colorScheme

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
            .padding(.bottom, 48)
        }
    }
}
