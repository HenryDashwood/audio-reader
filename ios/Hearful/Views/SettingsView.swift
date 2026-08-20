import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthController
    @State private var voiceID: String = SpeechVoice.current?.identifier ?? ""
    @State private var previewSpeaker = Speaker()
    @State private var naturalVoiceName: String = SpeechVoice.naturalVoice?.name ?? ""
    @State private var naturalVoices: [KokoroVoice] = []
    @State private var naturalPreview: KokoroSynthesizer?
    @State private var confirmingDelete = false
    @State private var confirmingDisableAI = false
    @State private var showingAIChoice = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var privacyError: String?
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

                // Only on a build that has the Kokoro package and the model
                // files. On any other, this section does not exist and the app
                // behaves exactly as it did before.
                if KokoroEngines.isAvailable {
                    Section {
                        Picker("Natural voice", selection: $naturalVoiceName) {
                            Text("Off — use the system voice").tag("")
                            ForEach(naturalVoices) { voice in
                                Text(voice.displayName).tag(voice.name)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    } header: {
                        Text("Natural voice (experimental)")
                    } footer: {
                        Text(
                            "Reads articles with a voice generated on this iPhone. It "
                                + "sounds closer to a person and needs no connection, but it "
                                + "takes a moment to start and uses more battery. Spoken "
                                + "replies keep the system voice. A change applies to the "
                                + "next article you open."
                        )
                    }
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

                Section {
                    Link("Privacy Policy", destination: AppConfiguration.privacyURL)
                    Link("Email Support", destination: AppConfiguration.supportURL)

                    if auth.user?.aiDataSharingConsented == true {
                        Button("Turn Off AI Data Sharing", role: .destructive) {
                            confirmingDisableAI = true
                        }
                        .accessibilityHint(
                            "Stops future spoken requests and library details being sent to AI providers"
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
                        "Voice requests use OpenRouter and an AI model provider only after you allow it. "
                            + "Turning it off leaves the rest of Hearful available."
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
            // Level with the search and microphone buttons rather than on a
            // line of its own below them: a large title in its own band costs
            // an inch of every screen before a single episode is shown.
            .toolbarTitleDisplayMode(.inlineLarge)
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
                    "Hearful will stop sending spoken requests and episode details to AI providers. "
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
            .onChange(of: voiceID) { _, identifier in
                SpeechVoice.select(identifier: identifier)
                // Hearing it is the only way to choose it.
                Task { await previewSpeaker.speak("This voice will read your articles.") }
            }
            // Asked of the engine rather than assumed: the catalogue is a
            // shortlist of names, and only the file on the device says which
            // of them are really there.
            .task {
                naturalVoices = await KokoroEngines.shared?.availableVoices() ?? []
            }
            .onChange(of: naturalVoiceName) { _, name in
                let voice = KokoroVoice.named(name)
                SpeechVoice.selectNatural(voice)
                naturalPreview?.stopSpeaking(at: .immediate)
                naturalPreview = nil
                // Hearing it is the only way to choose it — the same rule as
                // the system voices above, and more important here, where the
                // whole point is what it sounds like.
                guard let voice, let engine = KokoroEngines.shared else { return }
                let preview = KokoroSynthesizer(engine: engine, voice: voice)
                naturalPreview = preview
                preview.speak(AVSpeechUtterance(string: "This voice will read your articles."))
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
