import AppIntents

struct PlayEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a Listening Item"
    static let description = IntentDescription(
        "Plays a podcast or reads an article, continuing from your saved place.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$episode)") }

    @Parameter(title: "Item", requestValueDialog: "What would you like to listen to?")
    var episode: EpisodeEntity

    init() {}
    init(episode: EpisodeEntity) { self.episode = episode }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EpisodeEntity> & ProvidesDialog {
        do {
            let chosen = try await ShortcutPlayback.resolve(id: episode.id)
            try await ShortcutPlayback.start(chosen) {
                try await continueInForeground(IntentDialog("Opening Magpie to start listening."))
            }
            return .result(value: EpisodeEntity(chosen), dialog: IntentDialog("Starting \(chosen.title)."))
        } catch { throw ShortcutFailure.explaining(error) }
    }
}
