import OSLog

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "speech")

/// Falls back only before announcing readiness. Known capability failures
/// disable the preferred recognizer for this launch; unknown startup errors
/// get a short cooldown before it is tried again.
@MainActor
final class FallbackSpeechRecognizer: SpeechRecognizing {
    private let preferred: SpeechRecognizing
    private let backup: SpeechRecognizing
    private var preferredHasFailed = false
    private var retryPreferredAfter: ContinuousClock.Instant?
    private var activeID: UUID?

    func configure(vocabulary: [String], onCaptureEnded: @escaping @MainActor () -> Void) {
        preferred.configure(vocabulary: vocabulary, onCaptureEnded: onCaptureEnded)
        backup.configure(vocabulary: vocabulary, onCaptureEnded: onCaptureEnded)
    }

    func finishListening() {
        preferred.finishListening()
        backup.finishListening()
    }

    init(preferred: SpeechRecognizing, backup: SpeechRecognizing) {
        self.preferred = preferred
        self.backup = backup
    }

    func listen(onReady: @MainActor () -> Void) async throws -> String {
        try await listen(onReady: onReady, onPartial: { _ in })
    }

    func listen(
        onReady: @MainActor () -> Void,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let id = UUID()
        activeID = id
        var captured = false
        if !preferredHasFailed, retryPreferredAfter == nil || ContinuousClock.now >= retryPreferredAfter! {
            do {
                return try await preferred.listen(onReady: { captured = true; onReady() }, onPartial: onPartial)
            } catch is CancellationError {
                throw CancellationError()
            } catch is SpeechPermissionDenied {
                // Not a reason to try the backup — it needs the same
                // permission and would fail the same way, a second or two
                // later — and not a reason to write the preferred recogniser
                // off for the rest of the session either: it is fine, we are
                // simply not allowed to listen yet.
                throw SpeechPermissionDenied()
            } catch let error {
                preferred.cancel()
                guard activeID == id, !Task.isCancelled else { throw CancellationError() }
                if captured || error is any RecognitionFailureAfterCapture {
                    throw error
                }
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
                    if (error as? any TransientRecognitionFailure)?.isTransient == false {
                        preferredHasFailed = true
                    } else {
                        // A download or framework outage is not evidence that
                        // this recognizer will never work during this launch.
                        retryPreferredAfter = .now + .seconds(60)
                    }
                    log.notice(
                        "preferred recogniser failed, using backup: \(error.localizedDescription)")
                }
            }
        }
        guard activeID == id, !Task.isCancelled else { throw CancellationError() }
        return try await backup.listen(onReady: onReady, onPartial: onPartial)
    }

    func cancel() {
        activeID = nil
        preferred.cancel()
        backup.cancel()
    }
}
