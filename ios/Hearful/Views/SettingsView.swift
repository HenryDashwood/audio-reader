import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthController
    @State private var voiceID: String = SpeechVoice.current?.identifier ?? ""
    @State private var previewSpeaker = Speaker()
    @State private var naturalVoiceName: String = SpeechVoice.naturalVoice?.name ?? ""
    @State private var naturalVoices: [KokoroVoice] = []
    @State private var naturalPreview: KokoroSynthesizer?
    @ObservedObject private var naturalVoiceAssets = NaturalVoiceAssets.shared
    @State private var confirmingNaturalVoiceRemoval = false
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

                // The system voice remains the default. A physical-device
                // build can offer Kokoro as an explicit, removable download;
                // the simulator has no compatible Metal GPU and omits it.
                if KokoroEngines.isSupported {
                    Section {
                        switch naturalVoiceAssets.state {
                        case .checking:
                            HStack {
                                Text("Natural voices")
                                Spacer()
                                ProgressView()
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Checking natural voices")

                        case .notInstalled:
                            Button {
                                Task { await downloadNaturalVoices() }
                            } label: {
                                Label("Download Natural Voices", systemImage: "arrow.down.circle")
                            }
                            .accessibilityHint(
                                "Downloads about 350 megabytes. The system voice remains available."
                            )

                        case .waiting:
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Preparing natural voices…")
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Preparing natural voices download")

                                Button("Cancel Download") {
                                    Task { await cancelNaturalVoiceDownload() }
                                }
                            }

                        case .downloading(let fraction):
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Downloading natural voices…")
                                ProgressView(value: fraction)
                                    .accessibilityLabel("Natural voices download")
                                    .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))

                                Button("Cancel Download") {
                                    Task { await cancelNaturalVoiceDownload() }
                                }
                            }

                        case .paused(let fraction):
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Download paused")
                                ProgressView(value: fraction)
                                    .accessibilityLabel("Natural voices download paused")
                                    .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                                Text("It will resume automatically when downloading can continue.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)

                                Button("Cancel Download") {
                                    Task { await cancelNaturalVoiceDownload() }
                                }
                            }

                        case .cancelling(let fraction):
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Cancelling download…")
                                ProgressView(value: fraction)
                                    .accessibilityLabel("Cancelling natural voices download")
                                    .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                            }

                        case .installed:
                            Picker("Natural voice", selection: $naturalVoiceName) {
                                Text("Off — use the system voice").tag("")
                                ForEach(naturalVoices) { voice in
                                    Text(voice.displayName).tag(voice.name)
                                }
                            }
                            .pickerStyle(.navigationLink)

                            Button("Remove Download", role: .destructive) {
                                confirmingNaturalVoiceRemoval = true
                            }
                            .accessibilityHint(
                                "Frees the downloaded model and returns article reading to the system voice"
                            )

                        case .failed(let message):
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.red)
                            Button("Try Download Again") {
                                Task { await downloadNaturalVoices() }
                            }
                        }
                    } header: {
                        Text("Natural voice (experimental)")
                    } footer: {
                        Text(
                            "Optional download, about 350 MB. Once downloaded it reads "
                                + "articles entirely on this iPhone and needs no connection, "
                                + "but uses more battery. Spoken replies keep the system voice. "
                                + "A change applies next time you start or resume an article."
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
                "Remove natural voices?",
                isPresented: $confirmingNaturalVoiceRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Natural Voices", role: .destructive) {
                    Task { await removeNaturalVoices() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This frees about 350 MB. Articles will use your system voice. "
                        + "Downloading natural voices again will require an internet connection."
                )
            }
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
                await naturalVoiceAssets.refresh()
                if naturalVoiceAssets.state == .installed {
                    await loadNaturalVoices()
                }
            }
            // If Settings was recreated while a process-wide download was in
            // flight, populate this view's picker when that download finishes.
            .onChange(of: naturalVoiceAssets.state) { _, state in
                guard state == .installed else { return }
                Task { await loadNaturalVoices() }
            }
            .onChange(of: naturalVoiceName) { _, name in
                let voice = KokoroVoice.named(name)
                SpeechVoice.selectNatural(voice)
                ArticlePlayer.shared.voicePreferenceDidChange()
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

    private func loadNaturalVoices() async {
        naturalVoices = await KokoroEngines.shared?.availableVoices() ?? []
    }

    private func downloadNaturalVoices() async {
        await naturalVoiceAssets.download()
        switch naturalVoiceAssets.state {
        case .installed:
            await loadNaturalVoices()
            AccessibilityNotification.Announcement(
                "Natural voices downloaded. Choose a voice to hear a preview."
            ).post()
        case .failed(let message):
            AccessibilityNotification.Announcement(message).post()
        default:
            break
        }
    }

    private func cancelNaturalVoiceDownload() async {
        await naturalVoiceAssets.cancelDownload()
        AccessibilityNotification.Announcement("Cancelling natural voice download.").post()
    }

    private func removeNaturalVoices() async {
        naturalPreview?.stopSpeaking(at: .immediate)
        naturalPreview = nil
        await naturalVoiceAssets.remove()
        guard naturalVoiceAssets.state == .notInstalled else { return }
        naturalVoiceName = ""
        naturalVoices = []
        AccessibilityNotification.Announcement(
            "Natural voices removed. Hearful will use the system voice."
        ).post()
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
