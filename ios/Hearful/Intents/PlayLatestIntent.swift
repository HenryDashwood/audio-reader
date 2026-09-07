import AppIntents

struct PlayLatestIntent: AppIntent {
    static let title: LocalizedStringResource = "Play the Latest Item"
    static let description = IntentDescription("Plays the latest available podcast or article.")
    // Preserve the working plain AppIntent route while the native audio schema
    // integration is validated separately on devices.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EpisodeEntity> & ProvidesDialog {
        do {
            guard let episode = try await ShortcutLibrary.shared.find("", latestLimit: 20).first else {
                throw ShortcutFailure(message: "You have nothing available to listen to yet.")
            }
            let chosen = ShortcutPlayback.chooseFresh(episode)
            try await ShortcutPlayback.start(chosen) {
                try await continueInForeground(IntentDialog("Opening Magpie to start listening."))
            }
            return .result(value: EpisodeEntity(chosen), dialog: IntentDialog("Starting \(chosen.title)."))
        } catch { throw ShortcutFailure.explaining(error) }
    }
}
