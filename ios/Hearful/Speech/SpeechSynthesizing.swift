import AVFoundation

/// The part of the system speech synthesiser that ArticlePlayer uses.
///
/// It exists so the reader can be exercised without anything being said out
/// loud: the app injects the real synthesiser, tests inject a silent one.
/// Method names follow AVSpeechSynthesizer's so the call sites read the same.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    var delegate: SpeechSynthesizingDelegate? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }

    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary)
    func pauseSpeaking(at boundary: AVSpeechBoundary)
    func continueSpeaking()
}

/// What speech comes out of when nothing has been named.
@MainActor
enum SpeechSynthesizers {
    /// The system voice in the app, silence under test — so a test that
    /// builds a reader without saying otherwise cannot make the machine talk.
    /// A test wanting to watch what would have been said builds its own
    /// SilentSynthesizer and passes it in.
    static func make() -> SpeechSynthesizing {
        if TestEnvironment.isRunningTests { return SilentSynthesizer() }
        // Both conditions have to hold: she has chosen a natural voice, and
        // this build can actually render one. Either missing means the system
        // voice, which is the behaviour every build has had until now.
        if let voice = SpeechVoice.naturalVoice, let engine = KokoroEngines.shared {
            return KokoroSynthesizer(engine: engine, voice: voice)
        }
        return SystemSpeechSynthesizer()
    }
}

/// Which utterance a callback is about. The utterance itself is not Sendable,
/// so what crosses back to the main actor is its identity, not the object —
/// which is all the reader compares against anyway.
typealias UtteranceID = ObjectIdentifier

/// The two callbacks the reader needs: one to advance to the next chunk, one
/// to follow the position within the chunk being spoken. Deliberately no
/// equivalent of `didCancel` — a deliberate stop must not advance anything.
@MainActor
protocol SpeechSynthesizingDelegate: AnyObject {
    func speechFinished(_ utterance: UtteranceID)
    /// `fraction` is how far through the utterance's text the voice has
    /// reached, 0 to 1.
    func speechProgressed(toFraction fraction: Double, of utterance: UtteranceID)
}

/// The real thing: AVSpeechSynthesizer, with its delegate callbacks brought
/// back onto the main actor.
@MainActor
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    weak var delegate: SpeechSynthesizingDelegate?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
    var isPaused: Bool { synthesizer.isPaused }

    func speak(_ utterance: AVSpeechUtterance) {
        synthesizer.speak(utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) {
        synthesizer.stopSpeaking(at: boundary)
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) {
        synthesizer.pauseSpeaking(at: boundary)
    }

    func continueSpeaking() {
        synthesizer.continueSpeaking()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        // Only the identity is carried over: AVSpeechUtterance is not Sendable.
        let finished = UtteranceID(utterance)
        Task { @MainActor in self.delegate?.speechFinished(finished) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let speaking = UtteranceID(utterance)
        let fraction = Double(characterRange.location) / Double(max(utterance.speechString.count, 1))
        Task { @MainActor in
            self.delegate?.speechProgressed(toFraction: fraction, of: speaking)
        }
    }
}
