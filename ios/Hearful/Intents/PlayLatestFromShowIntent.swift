import AppIntents

struct PlayLatestFromShowIntent: AppIntent {
    static let title: LocalizedStringResource = "Play the Latest from a Show"
    static let description = IntentDescription("Plays the newest episode or article from a show you follow.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static var parameterSummary: some ParameterSummary { Summary("Play the latest from \(\.$show)") }

    @Parameter(title: "Show", requestValueDialog: "Which show or publication?") var show: ShowEntity
    init() {}
    init(show: ShowEntity) { self.show = show }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EpisodeEntity> & ProvidesDialog {
        do {
            guard let episode = try await ShortcutLibrary.shared.find("", showID: show.id).first else {
                throw ShortcutFailure(message: "\(show.title) has nothing available to listen to yet.")
            }
            let chosen = ShortcutPlayback.chooseFresh(episode)
            try await ShortcutPlayback.start(chosen) {
                try await continueInForeground(IntentDialog("Opening Magpie to start listening."))
            }
            return .result(value: EpisodeEntity(chosen), dialog: IntentDialog("Starting \(chosen.title)."))
        } catch { throw ShortcutFailure.explaining(error) }
    }
}
