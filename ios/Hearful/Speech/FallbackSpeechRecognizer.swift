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
            } catch is SpeechPermissionDenied {
                // Not a reason to try the backup — it needs the same
                // permission and would fail the same way, a second or two
                // later — and not a reason to write the preferred recogniser
                // off for the rest of the session either: it is fine, we are
                // simply not allowed to listen yet.
                throw SpeechPermissionDenied()
            } catch {
                // A failure about this attempt rather than about the
                // recogniser does not disqualify it. The microphone not
                // coming up on the first request after launch is the case
                // this exists for: writing the better recogniser off over it
                // would leave her on the weaker one until she restarts.
                if (error as? any TransientRecognitionFailure)?.isTransient == true {
                    log.notice(
                        "preferred recogniser failed this time, using backup: \(error.localizedDescription)"
                    )
                } else {
                    preferredHasFailed = true
                    log.notice(
                        "preferred recogniser failed, using backup: \(error.localizedDescription)")
                }
            }
        }
        return try await backup.listen(onReady: onReady)
    }

    func cancel() {
        preferred.cancel()
        backup.cancel()
    }
}
