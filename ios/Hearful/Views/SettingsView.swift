import SwiftUI

struct SettingsView: View {
    @AppStorage(VoiceConversationPreferences.keepListeningKey) private var keepListening = true
    @AppStorage(VoiceConversationPreferences.followUpWaitKey) private var followUpWait =
        VoiceConversationPreferences.defaultFollowUpWait
    @EnvironmentObject private var auth: AuthController
    @ObservedObject private var player = PlaybackCoordinator.shared
    @State private var systemVoiceID = ""
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var readout = SettingsReadout()
    @State private var deletionOwner: AuthController.SessionOwner?
    @State private var confirmingDisableAI: AuthController.SessionOwner?
    @State private var showingAIChoice: AuthController.SessionOwner?
    @State private var deletingOwner: AuthController.SessionOwner?
    private var deleting: Bool { deletingOwner != nil && deletingOwner == auth.sessionOwner }
    @State private var deleteError: String?
    @State private var privacyError: String?
    @State private var serverOverride = AppConfiguration.rememberedOverride()
    @State private var voices: [SpeechVoice.Choice] = []
    @State private var loadingVoices = true

    var body: some View {
        NavigationStack {
            List {
                Section { NavigationLink("Magpie Plus") { PlusView() } }
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
                            + "and articles. "
                            + "Article speed also applies to Magpie’s spoken replies."
                    )
                }

                NaturalVoiceSection()

                Section {
                    if loadingVoices {
                        ProgressView("Loading voices…")
                    } else if voices.isEmpty {
                        Text("No speech voice is available")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Voice", selection: Binding(
                            get: { systemVoiceID },
                            set: { identifier in
                                systemVoiceID = identifier
                                SpeechVoice.select(identifier: identifier)
                                // Only a user choice previews speech; loading
                                // the saved selection must remain silent.
                                readout.speak("This voice will read your articles.")
                            }
                        )) {
                            ForEach(voices) { voice in
                                Text(voice.label).tag(voice.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                } header: {
                    Text("Apple Voice")
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

                Section {
                    Toggle("Keep listening after replies", isOn: $keepListening)
                    if keepListening {
                        Picker("Wait for a reply", selection: $followUpWait) {
                            ForEach(VoiceConversationPreferences.waitOptions, id: \.self) { seconds in
                                Text("\(Int(seconds)) seconds").tag(seconds)
                            }
                        }
                    }
                } header: {
                    Text("Conversation")
                } footer: {
                    Text("After Magpie answers, wait for the listening sound and speak again. Silence ends listening; say “That’s all” to close the conversation. Starting playback also ends listening.")
                }

                Section {
                    DownloadsSettingsLink()
                } footer: {
                    Text("Keep episodes on this iPhone so they play without a connection.")
                }

                Section {
                    NavigationLink {
                        SiriShortcutsView()
                    } label: {
                        Label("Siri and Shortcuts", systemImage: "mic.badge.plus")
                    }
                }

                Section("Library") {
                    NavigationLink("Import subscriptions") { SubscriptionImportView() }
                    NavigationLink("Export subscriptions") { SubscriptionExportView() }
                }

                NewsletterAddressSection(readout: readout)
                    .id(auth.sessionOwner)

                Section {
                    Link("Privacy Policy", destination: AppConfiguration.privacyURL)
                    Link("Email Support", destination: AppConfiguration.supportURL)

                    if auth.user?.aiDataSharingConsented == true {
                        Button("Turn Off AI Data Sharing", role: .destructive) {
                            confirmingDisableAI = auth.sessionOwner
                        }
                        .accessibilityHint(
                            "Stops future spoken requests and library details being sent to OpenAI"
                        )
                    } else {
                        Button("Review AI Data Sharing") {
                            showingAIChoice = auth.sessionOwner
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
                    NavigationLink("Sign-in Methods") { SignInMethodsView(auth: auth) }
                    let owner = auth.sessionOwner
                    Button("Sign Out", role: .destructive) {
                        if let owner { Task { await auth.signOut(for: owner) } }
                    }
                    .accessibilityHint("Returns to the sign in screen")

                    Button("Delete Account", role: .destructive) {
                        if owner == auth.sessionOwner { deletionOwner = owner }
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
                isPresented: Binding(get: { deletionOwner != nil && deletionOwner == auth.sessionOwner },
                                     set: { if !$0 { deletionOwner = nil } }),
                titleVisibility: .visible, presenting: deletionOwner
            ) { owner in
                Button("Delete Account", role: .destructive) {
                    Task { await deleteAccount(confirmedFor: owner) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(
                    "This removes your account, the shows you follow, and your place in every "
                        + "episode. It cannot be undone. Deleting your account does not cancel Magpie Plus. "
                        + "Cancel your subscription in the App Store or Google Play to stop renewal."
                )
            }
            // An alert is centred and unambiguously modal. A confirmation
            // dialog becomes an anchored popover on this layout, and SwiftUI
            // was pointing its arrow at an unrelated section of the list.
            .alert(
                "Turn off AI data sharing?",
                isPresented: Binding(get: { confirmingDisableAI != nil }, set: { if !$0 { confirmingDisableAI = nil } }),
                presenting: confirmingDisableAI
            ) { owner in
                Button("Turn Off", role: .destructive) {
                    Task { await disableAIDataSharing(confirmedFor: owner) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(
                    "Magpie will stop sending spoken requests and episode details to OpenAI. "
                        + "You can turn it on again here later."
                )
            }
            .onChange(of: auth.sessionOwner) { _, _ in showingAIChoice = nil }
            .sheet(item: $showingAIChoice) { owner in
                AIDataSharingConsentView(owner: owner,
                    onAllowed: { showingAIChoice = nil },
                    onNotNow: { showingAIChoice = nil }
                )
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
            .task {
                let snapshot = await SpeechVoice.settingsSnapshot()
                guard !Task.isCancelled else { return }
                voices = snapshot.choices
                systemVoiceID = snapshot.selectedID
                loadingVoices = false
            }
        }
        .onChange(of: auth.sessionOwner) { _, _ in
            deletionOwner = nil
            confirmingDisableAI = nil
            privacyError = nil
            deleteError = nil
            readout.stop()
        }
        .onDisappear { readout.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { readout.stop() }
        }
    }

    @ViewBuilder
    private var playbackSpeedOptions: some View {
        ForEach(PlaybackSpeedPreference.rates, id: \.self) { rate in
            Text(speedLabel(rate)).tag(rate)
        }
    }

    private func speedLabel(_ rate: Float) -> String {
        let number =
            rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rate)) : String(format: "%g", rate)
        return "\(number)×"
    }

    private func deleteAccount(confirmedFor owner: AuthController.SessionOwner) async {
        guard owner == auth.sessionOwner, !deleting else { return }
        deletingOwner = owner
        deleteError = nil
        defer { if deletingOwner == owner { deletingOwner = nil } }
        do {
            try await auth.deleteAccount(confirmedFor: owner)
            // No success message: the app returns to the sign-in screen, which
            // is the confirmation.
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? APIError)?.spokenResponse ?? "Something went wrong."
            deleteError = message
            // Announced as well as shown — she is not watching the screen for
            // a red line to appear under a button she just tapped.
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private func disableAIDataSharing(confirmedFor owner: AuthController.SessionOwner) async {
        privacyError = nil
        do {
            try await auth.setAIDataSharing(granted: false, confirmedFor: owner)
            AccessibilityNotification.Announcement("AI data sharing is off.").post()
        } catch is CancellationError {
            return
        } catch let error as APIError {
            privacyError = error.spokenResponse
            AccessibilityNotification.Announcement(error.spokenResponse).post()
        } catch {
            privacyError = APIError.genericSpokenResponse
            AccessibilityNotification.Announcement(APIError.genericSpokenResponse).post()
        }
    }
}

/// Owns speech requested from Settings, including the time before the synthesizer starts.
@MainActor
final class SettingsReadout: ObservableObject {
    private let makeSpeaker: () -> any Speaking
    private lazy var speaker = makeSpeaker()
    private var task: Task<Void, Never>?

    init(makeSpeaker: @escaping () -> any Speaking = { Speaker() }) {
        self.makeSpeaker = makeSpeaker
    }

    @discardableResult
    func speak(_ text: String, expectedScope: String? = ShortcutScope.current) -> Task<Void, Never>? {
        guard expectedScope == ShortcutScope.current else { return nil }
        stop()
        let speaker = self.speaker
        let task = Task {
            guard !Task.isCancelled, expectedScope == ShortcutScope.current else { return }
            await speaker.speak(text)
        }
        self.task = task
        return task
    }

    func stop() {
        guard let task else { return }
        self.task = nil
        task.cancel()
        speaker.stop()
    }
}
