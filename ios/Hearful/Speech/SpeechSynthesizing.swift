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
    /// The text likely to be spoken next, so a synthesiser that is slow to start can get it ready.
    func prepare(_ text: String)
    func prepare(_ text: String, startsNewParagraph: Bool)
}

extension SpeechSynthesizing {
    func prepare(_ text: String) {}
    func prepare(_ text: String, startsNewParagraph: Bool) { prepare(text) }
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
        if let natural = NaturalVoiceStore.selected() {
            return NaturalVoiceSynthesizer(folder: natural.folder, voice: natural.voice)
        }
        return SystemSpeechSynthesizer()
    }

    /// What reads a passage the chosen voice has failed on: always the system
    /// voice, which needs no download and no model. Silence under test.
    static func makeFallback() -> SpeechSynthesizing {
        if TestEnvironment.isRunningTests { return SilentSynthesizer() }
        return SystemSpeechSynthesizer()
    }

    /// Start loading the selected natural voice while article text and shared
    /// bookmarks are fetched. This only loads models; it never starts audio.
    static func warmUp() {
        guard !TestEnvironment.isRunningTests, let natural = NaturalVoiceStore.selected() else { return }
        _ = NaturalVoiceSynthesizer.engine(folder: natural.folder, voice: natural.voice)
    }

    /// Which synthesiser `make()` would give now. ArticlePlayer compares it before each chunk, so a voice chosen in
    /// Settings takes over at the next chunk rather than cutting off the one being read.
    static func identity() -> String {
        if TestEnvironment.isRunningTests { return "silent" }
        return NaturalVoiceStore.selected().map { "natural:\($0.voice.id)" } ?? "system"
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
    /// The exact UTF-16 range Apple says it is about to speak. Keeping the
    /// range, rather than reducing it to a percentage here, lets the article
    /// on screen follow the actual word as well as the playback clock.
    func speechProgressed(to range: NSRange, of utterance: UtteranceID)
    /// The utterance can no longer be heard and will never finish: the audio
    /// output died under it. The reader has to start it again on a new one.
    func speechFailed(_ utterance: UtteranceID)
}

extension SpeechSynthesizingDelegate {
    func speechFailed(_ utterance: UtteranceID) {}
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
        Task { @MainActor in
            self.delegate?.speechProgressed(to: characterRange, of: speaking)
        }
    }
}
