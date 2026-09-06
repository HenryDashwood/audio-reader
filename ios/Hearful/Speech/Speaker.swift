import AVFoundation

/// Reads confirmations and clarifications aloud. On-device, free, and offline.
@MainActor
final class Speaker: NSObject, Speaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var utteranceID: ObjectIdentifier?
    private var attempt: VoiceAttempt?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Returns only once the sentence has actually finished, so callers can
    /// rely on speech and podcast audio never overlapping.
    func speak(_ text: String) async {
        stop()
        try? AudioSession.configureForPlayback()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoice.current
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            self.utteranceID = ObjectIdentifier(utterance)
            self.attempt = VoiceAttempt.current
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finish()
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.utteranceID == id else { return }
            self.finish()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.utteranceID == id else { return }
            self.finish()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.utteranceID == id else { return }
            self.attempt?.markAudibleResponse()
        }
    }

    private func finish() {
        // Resuming twice would trap, so the continuation is cleared first.
        let pending = continuation
        continuation = nil
        utteranceID = nil
        attempt = nil
        pending?.resume()
    }
}
