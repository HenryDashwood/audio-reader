import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthController
    @State private var voiceID: String = SpeechVoice.current?.identifier ?? ""
    @State private var previewSpeaker = Speaker()
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var serverOverride = AppConfiguration.rememberedOverride()
    private let voices = SpeechVoice.englishVoices()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Reading voice", selection: $voiceID) {
                        ForEach(voices, id: \.identifier) { voice in
                            Text(label(for: voice)).tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Voice")
                } footer: {
                    Text(
                        "Used for articles and spoken replies. Better voices — "
                            + "including Alex — can be downloaded free in "
                            + "Settings → Accessibility → Spoken Content → Voices, "
                            + "and appear here once installed."
                    )
                }

                // Only ever visible on a phone that has been launched from
                // Xcode against a local backend. On a normal install there is
                // no override, and this section does not exist.
                if let override = serverOverride {
                    Section {
                        Text(override)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                        Button("Use the normal server") {
                            AppConfiguration.clearRememberedOverride()
                            serverOverride = nil
                            AccessibilityNotification.Announcement(
                                "Now using the normal server. Quit and reopen Hearful."
                            ).post()
                        }
                    } header: {
                        Text("Server")
                    } footer: {
                        Text(
                            "Hearful is talking to a test server instead of the usual one. "
                                + "Changing this takes effect next time the app is opened."
                        )
                    }
                }

                Section("Account") {
                    Button("Sign Out", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                    .accessibilityHint("Returns to the sign in screen")

                    Button("Delete Account", role: .destructive) {
                        confirmingDelete = true
                    }
                    .accessibilityHint(
                        "Permanently removes your account, your shows and your place in every episode"
                    )
                    if let deleteError {
                        Text(deleteError).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            // A confirmation dialog rather than an alert: it reads the
            // consequence out as part of the choice, so the destructive button
            // is never the first thing VoiceOver lands on unexplained.
            .confirmationDialog(
                "Delete your account?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This removes your account, the shows you follow, and your place in every "
                        + "episode. It cannot be undone."
                )
            }
            .disabled(deleting)
            .overlay {
                if deleting {
                    ProgressView("Deleting your account…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onChange(of: voiceID) { _, identifier in
                SpeechVoice.select(identifier: identifier)
                // Hearing it is the only way to choose it.
                Task { await previewSpeaker.speak("This voice will read your articles.") }
            }
        }
    }

    private func deleteAccount() async {
        deleting = true
        deleteError = nil
        defer { deleting = false }
        do {
            try await auth.deleteAccount()
            // No success message: the app returns to the sign-in screen, which
            // is the confirmation.
        } catch {
            let message = (error as? APIError)?.spokenResponse ?? "Something went wrong."
            deleteError = message
            // Announced as well as shown — she is not watching the screen for
            // a red line to appear under a button she just tapped.
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private func label(for voice: AVSpeechSynthesisVoice) -> String {
        var parts = [voice.name]
        if let region = voice.language.split(separator: "-").last {
            parts.append(region == "GB" ? "UK" : String(region))
        }
        switch voice.quality {
        case .premium: parts.append("Premium")
        case .enhanced: parts.append("Enhanced")
        default: parts.append(SpeechVoice.isNatural(voice) ? "Standard" : "Robotic")
        }
        return parts.joined(separator: " · ")
    }
}
