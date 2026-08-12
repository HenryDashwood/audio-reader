import OSLog

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "speech")

/// Tries the preferred recogniser, then the backup. Once the preferred one has
/// failed it is not tried again for the lifetime of the app: a recogniser that
/// cannot initialise fails the same way every time, and retrying costs a
/// second or two on every command.
@MainActor
final class FallbackSpeechRecognizer: SpeechRecognizing {
    private let preferred: SpeechRecognizing
    private let backup: SpeechRecognizing
    private var preferredHasFailed = false

    init(preferred: SpeechRecognizing, backup: SpeechRecognizing) {
        self.preferred = preferred
        self.backup = backup
    }

    func listen(onReady: @MainActor () -> Void) async throws -> String {
        if !preferredHasFailed {
            do {
                return try await preferred.listen(onReady: onReady)
            } catch {
                preferredHasFailed = true
                log.notice("preferred recogniser failed, using backup: \(error.localizedDescription)")
            }
        }
        return try await backup.listen(onReady: onReady)
    }

    func cancel() {
        preferred.cancel()
        backup.cancel()
    }
}
