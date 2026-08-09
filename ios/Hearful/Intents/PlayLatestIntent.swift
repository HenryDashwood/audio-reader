import AppIntents
import AVFoundation
import Foundation
import OSLog

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "intents")

/// "Hey Siri, play the latest on Hearful."
///
/// A plain AppIntent rather than an AudioPlaybackIntent: the latter is a
/// system intent that Siri declined to run for this app. This tries to start
/// playback in the background and only asks to come to the foreground if the
/// audio session refuses — so in the good case she never sees the app.
struct PlayLatestIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Play the Latest Episode"
    static let description = IntentDescription("Plays the most recent episode.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        log.info("PlayLatestIntent invoked")
        let api = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)

        let episodes: [Episode]
        do {
            episodes = try await api.recentEpisodes(limit: 1)
        } catch let error as APIError where error.isAuthFailure {
            log.notice("intent ran without a valid session")
            return .result(dialog: IntentDialog("Please open Hearful and sign in first."))
        } catch {
            log.error("could not fetch latest: \(error.localizedDescription)")
            return .result(dialog: IntentDialog("I could not reach your podcasts just now."))
        }

        guard let episode = episodes.first else {
            return .result(dialog: IntentDialog("You have no episodes yet."))
        }

        do {
            try PlaybackCoordinator.shared.play(episode)
        } catch {
            // iOS would not let us take the audio session from the background.
            // Ask to come forward and play there, rather than claiming success
            // and producing silence.
            log.notice("background playback refused, continuing in foreground")
            throw needsToContinueInForegroundError(
                IntentDialog("Opening Hearful to play \(episode.title).")
            ) {
                try PlaybackCoordinator.shared.play(episode)
            }
        }

        log.info("playing \(episode.title)")
        return .result(dialog: IntentDialog("Playing \(episode.title)."))
    }
}
