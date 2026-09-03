import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthController
    @ObservedObject private var player = PlaybackCoordinator.shared
    @State private var systemVoiceID: String = SpeechVoice.current?.identifier ?? ""
    @State private var previewSpeaker = Speaker()
    @State private var confirmingDelete = false
    @State private var confirmingDisableAI = false
    @State private var showingAIChoice = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var privacyError: String?
    @State private var serverOverride = AppConfiguration.rememberedOverride()
    private let voices = SpeechVoice.installedVoices()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(
                        "Podcasts",
                        selection: Binding(
                            get: { player.podcastPlaybackRate },
                            set: { player.setPodcastPlaybackRate($0) }
                        )
                    ) {
                        playbackSpeedOptions
                    }

                    Picker(
                        "Articles",
                        selection: Binding(
                            get: { player.articlePlaybackRate },
                            set: { player.setArticlePlaybackRate($0) }
                        )
                    ) {
                        playbackSpeedOptions
                    }
                } header: {
                    Text("Playback Speed")
                } footer: {
                    Text(
                        "Magpie remembers separate speeds for recorded podcasts "
                            + "and articles read by the system voice."
                    )
                }

                Section {
                    if voices.isEmpty {
                        Text("No speech voice is available")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Voice", selection: $systemVoiceID) {
                            ForEach(voices, id: \.identifier) { voice in
                                Text(label(for: voice)).tag(voice.identifier)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text(
                        "Magpie shows every voice available on this iPhone. Download "
                            + "higher-quality Apple voices in "
                            + "Settings → Accessibility → Spoken Content → Voices, "
                            + "then reopen Magpie Settings."
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
                            NotificationCenter.default.post(
                                name: .hearfulServerChanged,
                                object: nil
                            )
                            Task { await auth.refreshUser() }
                            AccessibilityNotification.Announcement(
                                "Now using the normal server."
                            ).post()
                        }
                    } header: {
                        Text("Server")
                    } footer: {
                        Text(
                            "Magpie is talking to a test server instead of the usual one. "
                                + "Changing this takes effect immediately."
                        )
                    }
                }

                NewsletterAddressSection()

                Section {
                    Link("Privacy Policy", destination: AppConfiguration.privacyURL)
                    Link("Email Support", destination: AppConfiguration.supportURL)

                    if auth.user?.aiDataSharingConsented == true {
                        Button("Turn Off AI Data Sharing", role: .destructive) {
                            confirmingDisableAI = true
                        }
                        .accessibilityHint(
                            "Stops future spoken requests and library details being sent to OpenAI"
                        )
                    } else {
                        Button("Review AI Data Sharing") {
                            showingAIChoice = true
                        }
                    }

                    if let privacyError {
                        Text(privacyError).font(.callout).foregroundStyle(.red)
                    }
                } header: {
                    Text("Privacy & Support")
                } footer: {
                    Text(
                        "Voice requests use OpenAI only after you allow it. "
                            + "Turning it off leaves the rest of Magpie available."
                    )
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { MicToolbarButton() }
            }
            // Keep the title in one place rather than changing its size and
            // alignment when the list scrolls.
            .toolbarTitleDisplayMode(.inline)
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
            // An alert is centred and unambiguously modal. A confirmation
            // dialog becomes an anchored popover on this layout, and SwiftUI
            // was pointing its arrow at an unrelated section of the list.
            .alert(
                "Turn off AI data sharing?",
                isPresented: $confirmingDisableAI
            ) {
                Button("Turn Off", role: .destructive) {
                    Task { await disableAIDataSharing() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Magpie will stop sending spoken requests and episode details to OpenAI. "
                        + "You can turn it on again here later."
                )
            }
            .sheet(isPresented: $showingAIChoice) {
                AIDataSharingConsentView(
                    onAllowed: { showingAIChoice = false },
                    onNotNow: { showingAIChoice = false })
                    .environmentObject(auth)
                    .presentationDetents([.fraction(0.68), .large])
            }
            .disabled(deleting)
            .overlay {
                if deleting {
                    ProgressView("Deleting your account…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onChange(of: systemVoiceID) { _, identifier in
                SpeechVoice.select(identifier: identifier)
                // Hearing it is the only way to choose it.
                Task { await previewSpeaker.speak("This voice will read your articles.") }
            }
        }
    }

    @ViewBuilder
    private var playbackSpeedOptions: some View {
        ForEach(PlaybackSpeedPreference.rates, id: \.self) { rate in
            Text(speedLabel(rate)).tag(rate)
        }
    }

    private func speedLabel(_ rate: Float) -> String {
        let number = rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rate)) : String(format: "%g", rate)
        return "\(number)×"
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

    private func disableAIDataSharing() async {
        privacyError = nil
        do {
            try await auth.setAIDataSharing(granted: false)
            AccessibilityNotification.Announcement("AI data sharing is off.").post()
        } catch let error as APIError {
            privacyError = error.spokenResponse
            AccessibilityNotification.Announcement(error.spokenResponse).post()
        } catch {
            privacyError = APIError.genericSpokenResponse
            AccessibilityNotification.Announcement(APIError.genericSpokenResponse).post()
        }
    }

    private func label(for voice: AVSpeechSynthesisVoice) -> String {
        let parts = [voice.name, voice.language, SpeechVoice.qualityName(voice.quality)]
        return parts.joined(separator: " · ")
    }
}
