import AppIntents
import Foundation

/// "Hey Siri, play the one about the aliens lady on Hearful."
///
/// A plain AppIntent: Siri declined to run this app's AudioPlaybackIntent at
/// all. It tries to start playback in the background and only comes forward if
/// the audio session refuses.
struct PlayEpisodeIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Play an Episode"
    static let description = IntentDescription("Plays a podcast episode.")
    static let openAppWhenRun = false

    /// When Siri cannot fill this from the phrase — which is most of the time,
    /// since it only matches suggested episodes, not free text — it asks. Her
    /// answer then goes through the backend's own resolution, so "the last Joe
    /// Rogan" works even though no phrase could have contained it.
    @Parameter(title: "Episode", requestValueDialog: "What would you like to listen to?")
    var episode: EpisodeEntity

    init() {}
    init(episode: EpisodeEntity) { self.episode = episode }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let chosen = episode.episode
        do {
            try AudioPlayer.shared.play(chosen)
        } catch {
            throw needsToContinueInForegroundError(
                IntentDialog("Opening Hearful to play \(episode.title).")
            ) {
                try AudioPlayer.shared.play(chosen)
            }
        }
        // Short, because Siri reads it out before the episode begins.
        return .result(dialog: IntentDialog("Playing \(episode.title)."))
    }
}
