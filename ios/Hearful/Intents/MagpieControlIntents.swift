import AppIntents

// Compiled into both targets so WidgetKit can route the foreground action to
// the app process. The extension contains no authentication or playback state.
struct OpenMagpieMicrophoneControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Magpie"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let isDiscoverable = false
    @MainActor
    func perform() async throws -> some IntentResult {
        #if !HEARFUL_CONTROLS_EXTENSION
            VoicePrompt.request()
        #endif
        return .result()
    }
}

struct ContinueMagpieControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let isDiscoverable = false
    @MainActor
    func perform() async throws -> some IntentResult {
        #if !HEARFUL_CONTROLS_EXTENSION
            _ = try await ContinueListeningIntent().perform()
        #endif
        return .result()
    }
}
