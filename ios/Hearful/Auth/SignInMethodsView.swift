import AuthenticationServices
import SwiftUI

struct SignInMethodsView: View {
    @ObservedObject var auth: AuthController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                Text("Connect Apple and Google to use either to sign in. If both already have Magpie accounts, connecting combines their subscriptions, saved articles, and listening progress.")
            }
            if let providers = auth.linkedProviders {
                Section("Apple") {
                    if providers.contains("apple") {
                        Label("Connected", systemImage: "checkmark.circle")
                    } else {
                        Text("Connect your Apple account")
                        SignInWithAppleButton(.continue) { $0.requestedScopes = [.email] } onCompletion: { result in
                            Task { await auth.linkApple(result: result) }
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 56)
                        .disabled(auth.isAuthenticating)
                    }
                }
                Section("Google") {
                    if providers.contains("google") {
                        Label("Connected", systemImage: "checkmark.circle")
                    } else {
                        Text("Connect your Google account")
                        GoogleAuthenticationButton(title: "Continue with Google") { Task { await auth.linkGoogle() } }
                            .disabled(auth.isAuthenticating || !auth.googleIsConfigured)
                        if !auth.googleIsConfigured {
                            Text("Google sign-in is not available in this build yet.").font(.footnote)
                        }
                    }
                }
            } else if auth.linkingError == nil {
                ProgressView("Loading sign-in methods…")
            }
            if auth.isAuthenticating { ProgressView("Connecting account…") }
            if let error = auth.linkingError {
                Text(error).foregroundStyle(.red)
                if auth.linkedProviders == nil {
                    Button("Try Again") { Task { await auth.refreshLinkedProviders() } }
                }
            }
            Section {
                Text("Connecting requires signing in with the additional provider. Matching email addresses alone do not connect accounts. After combining accounts, review AI Data Sharing in Settings. Devices signed in to the other account will need to sign in again.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Sign-in Methods")
        .task { await auth.refreshLinkedProviders() }
    }
}
