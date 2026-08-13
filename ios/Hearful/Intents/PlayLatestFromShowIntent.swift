import AppIntents
import Foundation

/// "Hey Siri, play the latest Average Joe on Hearful."
///
/// The show is a phrase parameter matched against her subscriptions, so one
/// breath works — no follow-up question — for any show she already follows.
/// The newest item plays whether it is a podcast episode or an article.
struct PlayLatestFromShowIntent: AppIntent {
    static let title: LocalizedStringResource = "Play the Latest from a Show"
    static let description = IntentDescription(
        "Plays the newest episode or article from one of your shows.")
    /// Background first, coming forward only if the audio session refuses.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Show", requestValueDialog: "Which show?")
    var show: ShowEntity

    init() {}
    init(show: ShowEntity) { self.show = show }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let api = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)
        let episodes: [Episode]
        do {
            episodes = try await api.episodes(showID: show.id)
        } catch let error as APIError where error.isAuthFailure {
            return .result(dialog: IntentDialog("Please open Hearful and sign in first."))
        } catch {
            return .result(dialog: IntentDialog("I could not reach \(show.title) just now."))
        }

        guard let episode = episodes.first(where: {
            $0.audioURL != nil || $0.hasText == true
        }) else {
            return .result(dialog: IntentDialog("\(show.title) has nothing I can play yet."))
        }

        do {
            try PlaybackCoordinator.shared.play(episode)
        } catch {
            // iOS would not let us take the audio session from the background.
            try await continueInForeground(
                IntentDialog("Opening Hearful to play \(episode.title)."))
            try PlaybackCoordinator.shared.play(episode)
        }
        return .result(dialog: IntentDialog("Playing \(episode.title)."))
    }
}
