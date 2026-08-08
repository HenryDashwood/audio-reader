import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthController

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    Button("Sign Out", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                    .accessibilityHint("Returns to the sign in screen")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
