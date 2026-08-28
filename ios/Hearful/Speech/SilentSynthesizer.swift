import AVFoundation

/// A synthesiser that says nothing.
///
/// What an ArticlePlayer gets under test, so the suite cannot read the
/// fixture articles out of the Mac's speakers. It lives in the app target
/// rather than the test one only because the default has to be able to reach
/// it; nothing in the app uses it otherwise.
///
/// It records what would have been spoken, and lets a test deliver the
/// callbacks the real one delivers as it works through an utterance.
@MainActor
final class SilentSynthesizer: SpeechSynthesizing {
    weak var delegate: SpeechSynthesizingDelegate?

    /// Every utterance handed to it, in order.
    private(set) var spoken: [AVSpeechUtterance] = []
    /// Matches AVSpeechSynthesizer: still "speaking" while paused.
    private(set) var isSpeaking = false
    private(set) var isPaused = false

    var lastSpoken: String? { spoken.last?.speechString }

    func speak(_ utterance: AVSpeechUtterance) {
        spoken.append(utterance)
        isSpeaking = true
        isPaused = false
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) {
        isSpeaking = false
        isPaused = false
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) {
        guard isSpeaking else { return }
        isPaused = true
    }

    func continueSpeaking() {
        isPaused = false
    }

    // MARK: - Driving the player

    /// The current utterance reaching its end, which is what advances the
    /// reader to the next chunk. Nothing calls the delegate on its own here,
    /// so a test that wants the article to progress says so explicitly.
    func finishSpeaking() {
        guard let utterance = spoken.last, isSpeaking else { return }
        isSpeaking = false
        isPaused = false
        delegate?.speechFinished(UtteranceID(utterance))
    }

    /// The voice reaching a point part-way through the current utterance,
    /// which is what moves the position along within a chunk. This convenience
    /// keeps the older timeline tests expressive; range-sensitive tests use
    /// `speak(range:)` below.
    func speakOn(toFraction fraction: Double) {
        guard let utterance = spoken.last, isSpeaking else { return }
        let length = (utterance.speechString as NSString).length
        let location = min(max(Int(Double(length) * fraction), 0), length)
        delegate?.speechProgressed(
            to: NSRange(location: location, length: location < length ? 1 : 0),
            of: UtteranceID(utterance))
    }

    /// Delivers the same UTF-16 range as AVSpeechSynthesizer's per-word
    /// delegate callback.
    func speak(range: NSRange) {
        guard let utterance = spoken.last, isSpeaking else { return }
        delegate?.speechProgressed(to: range, of: UtteranceID(utterance))
    }
}
