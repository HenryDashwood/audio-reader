import AppIntents
import Foundation

/// "Hey Siri, subscribe on Hearful." — Siri asks which show, she answers
/// freely, and the backend does the rest.
///
/// The name is a free-text parameter, so it cannot appear inside the App
/// Shortcut phrase itself (Siri only matches phrase parameters against
/// enumerable entities). The flow is therefore always two-step: the phrase
/// triggers the intent, the follow-up question captures the name — which is
/// exactly what lets "Liam Halligan's Substack" work, since the answer goes
/// through the backend's full search-and-discovery path rather than Siri's
/// own matching.
struct SubscribeIntent: AppIntent {
    static let title: LocalizedStringResource = "Subscribe to a Show"
    static let description = IntentDescription(
        "Follows a podcast, blog or newsletter by name.")
    // Purely a network call and a spoken confirmation: no reason to ever put
    // the app on screen for it.
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Show or publication",
        requestValueDialog: "Which show or publication would you like to follow?")
    var name: String

    init() {}
    init(name: String) { self.name = name }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let api = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)
        let response: CommandResponse
        do {
            // Through the same backend path as the in-app microphone: the
            // model extracts the show's name, the directory is searched, and
            // unknown blogs go through web discovery.
            response = try await api.command(transcript: "subscribe to \(name)")
        } catch let error as APIError where error.isAuthFailure {
            return .result(dialog: IntentDialog("Please open Hearful and sign in first."))
        } catch let error as APIError {
            return .result(dialog: IntentDialog("\(error.spokenResponse)"))
        } catch {
            return .result(dialog: IntentDialog("Sorry, that did not work. Please try again."))
        }
        // If the app happens to be running, its library refreshes in place —
        // and Siri relearns the show names it can match in spoken phrases,
        // so "play the latest X" works for the show she just added.
        NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
        HearfulShortcuts.updateAppShortcutParameters()
        return .result(dialog: IntentDialog("\(response.spokenResponse)"))
    }
}
