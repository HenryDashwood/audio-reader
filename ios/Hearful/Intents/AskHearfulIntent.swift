import AppIntents
import Foundation

/// "Hey Siri, ask Hearful." — opens the app with the microphone already
/// listening, so the request itself is completely free-form and goes through
/// the backend's own understanding rather than Siri's phrase matching.
///
/// This is the escape hatch from Siri's limits: anything the registered
/// phrases cannot express ("subscribe to the article feed of
/// henrydashwood.com") is one sentence away once the sheet is up. It also
/// makes a good Action button shortcut: one press, then talk.
struct AskHearfulIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Hearful"
    static let description = IntentDescription(
        "Opens Hearful listening, ready for you to say what you'd like to hear.")
    // The whole point is to arrive in the app with the mic live; there is no
    // background version of this intent.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        VoicePrompt.request()
        return .result()
    }
}

/// Hand-off from the intent to the UI. Both a flag and a notification: on a
/// cold launch the intent may run before ContentView exists (the flag is
/// checked when it appears); when the app is already up, the notification
/// presents the sheet immediately.
@MainActor
enum VoicePrompt {
    private(set) static var pending = false

    static func request() {
        pending = true
        NotificationCenter.default.post(name: .hearfulAskByVoice, object: nil)
    }

    /// Returns whether a prompt was pending, and clears it.
    static func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}

extension Notification.Name {
    nonisolated static let hearfulAskByVoice = Notification.Name("hearfulAskByVoice")
}
