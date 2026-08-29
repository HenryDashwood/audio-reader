import AppIntents
import Foundation

/// "Hey Siri, play the one about the aliens lady on Magpie."
///
/// A plain AppIntent: Siri declined to run this app's AudioPlaybackIntent at
/// all. It tries to start playback in the background and only comes forward if
/// the audio session refuses.
struct PlayEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play an Episode"
    static let description = IntentDescription("Plays a podcast episode.")
    /// Background first — the good case never shows the app at all — with
    /// `.dynamic` foreground held in reserve for when the audio session
    /// refuses to be taken from the background. Replaces `openAppWhenRun` and
    /// `ForegroundContinuableIntent`, both deprecated in iOS 26.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

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
            try PlaybackCoordinator.shared.play(chosen)
        } catch {
            // Unlike the throwing call this replaces, this returns once the
            // app is forward, so the retry happens here rather than in a
            // continuation closure — and the confirmation below is still
            // reached and still spoken.
            try await continueInForeground(
                IntentDialog("Opening Magpie to play \(episode.title)."))
            try PlaybackCoordinator.shared.play(chosen)
        }
        // Short, because Siri reads it out before the episode begins.
        return .result(dialog: IntentDialog("Playing \(episode.title)."))
    }
}
