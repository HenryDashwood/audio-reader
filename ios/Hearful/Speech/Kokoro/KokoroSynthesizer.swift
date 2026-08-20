import AVFoundation
import Foundation

/// Reads with Kokoro instead of with Apple's voice.
///
/// It stands exactly where SystemSpeechSynthesizer stands: ArticlePlayer hands
/// it an utterance and waits for the same two callbacks, so nothing in the
/// reader, the scrubber, the lock screen or the saved positions changes. The
/// protocol asks for a *fraction* through the chunk rather than word ranges,
/// which is why an engine that returns nothing but samples can be dropped in
/// at all — the playhead is the fraction.
///
/// The one thing it has to do that AVSpeechSynthesizer did for us is hide the
/// wait. Rendering a whole 320-character chunk before saying anything would be
/// several seconds of silence after she presses play, so a chunk is split into
/// sentences, and the first is spoken while the rest are still being made.
@MainActor
final class KokoroSynthesizer: SpeechSynthesizing {
    weak var delegate: SpeechSynthesizingDelegate?

    /// Matches AVSpeechSynthesizer: still speaking while paused.
    private(set) var isSpeaking = false
    private(set) var isPaused = false

    private let engine: KokoroRendering
    private let output: KokoroAudioOutputting
    private let voice: KokoroVoice

    private var current: UtteranceID?
    private var renderTask: Task<Void, Never>?
    private var progressTimer: Timer?

    /// What has been rendered of the utterance so far, in seconds and in
    /// characters, so the part that does not exist yet can be estimated from
    /// the part that does.
    private var renderedDuration: TimeInterval = 0
    private var renderedCharacters = 0
    private var totalCharacters = 0
    private var isRenderComplete = false

    /// Short enough that the first one is quick, long enough that Kokoro still
    /// hears a sentence's worth of context for its prosody.
    static let segmentCharacterLimit = 180
    /// A single sentence longer than this is broken at a word boundary rather
    /// than risking Kokoro's 510-token ceiling.
    static let hardSegmentCharacterLimit = 300
    /// Fallback pace, used only until the first segment has been rendered.
    private static let charactersPerSecond = 16.4
    private static let progressInterval: TimeInterval = 0.1

    init(
        engine: KokoroRendering,
        voice: KokoroVoice,
        output: KokoroAudioOutputting = KokoroAudioEngineOutput()
    ) {
        self.engine = engine
        self.voice = voice
        self.output = output
    }

    // MARK: - SpeechSynthesizing

    func speak(_ utterance: AVSpeechUtterance) {
        stopSpeaking(at: .immediate)

        let id = UtteranceID(utterance)
        let text = utterance.speechString
        let speed = Self.speed(forUtteranceRate: utterance.rate)
        let segments = Self.segments(of: text)

        current = id
        totalCharacters = max(text.count, 1)
        isSpeaking = true
        isPaused = false
        output.onDrained = { [weak self] in self?.drained(id) }
        startProgressTimer()

        renderTask = Task { [engine, voice] in
            for segment in segments {
                if Task.isCancelled { return }
                do {
                    let audio = try await engine.render(
                        text: segment, voice: voice, speed: speed)
                    if Task.isCancelled { return }
                    self.accept(audio, characters: segment.count, for: id)
                } catch {
                    // One bad segment must not strand the article: stop
                    // rendering and let what has been spoken finish, which
                    // advances the reader to the next chunk.
                    break
                }
            }
            if Task.isCancelled { return }
            self.renderingFinished(for: id)
        }
    }

    /// The boundary is ignored: there is nothing to finish at a word, because
    /// what is playing is a rendered buffer rather than a voice mid-sentence.
    func stopSpeaking(at boundary: AVSpeechBoundary) {
        renderTask?.cancel()
        renderTask = nil
        stopProgressTimer()
        output.stop()
        current = nil
        renderedDuration = 0
        renderedCharacters = 0
        totalCharacters = 0
        isRenderComplete = false
        isSpeaking = false
        isPaused = false
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) {
        guard isSpeaking, !isPaused else { return }
        isPaused = true
        output.pause()
    }

    func continueSpeaking() {
        guard isPaused else { return }
        isPaused = false
        output.resume()
    }

    // MARK: - Rendering

    private func accept(_ audio: KokoroAudio, characters: Int, for id: UtteranceID) {
        guard current == id else { return }
        renderedDuration += audio.duration
        renderedCharacters += characters
        output.enqueue(audio)
    }

    private func renderingFinished(for id: UtteranceID) {
        guard current == id else { return }
        isRenderComplete = true
        if renderedDuration == 0 {
            // Nothing was ever made — a missing voice, or a first segment that
            // threw. Report the chunk as done so the article keeps moving.
            drained(id)
            return
        }
        output.finishEnqueueing()
    }

    private func drained(_ id: UtteranceID) {
        guard current == id else { return }
        stopProgressTimer()
        current = nil
        isSpeaking = false
        isPaused = false
        delegate?.speechFinished(id)
    }

    // MARK: - Progress

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(
            withTimeInterval: Self.progressInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.reportProgress() }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func reportProgress() {
        guard let id = current, !isPaused else { return }
        delegate?.speechProgressed(toFraction: fraction, of: id)
    }

    /// How far through the chunk the voice has reached.
    ///
    /// While the tail of the chunk is still being rendered its length is not
    /// known, so it is estimated from the pace of what has been rendered
    /// already — which is far more accurate than a words-per-minute guess,
    /// because it is this voice at this speed on this text.
    var fraction: Double {
        let total = estimatedDuration
        guard total > 0 else { return 0 }
        return min(max(output.elapsed / total, 0), 1)
    }

    private var estimatedDuration: TimeInterval {
        if isRenderComplete { return renderedDuration }
        guard renderedCharacters > 0 else {
            return Double(totalCharacters) / Self.charactersPerSecond
        }
        let perCharacter = renderedDuration / Double(renderedCharacters)
        return perCharacter * Double(totalCharacters)
    }

    // MARK: - Mapping the reader's knobs

    /// AVSpeechUtterance's rate back to a plain multiplier.
    ///
    /// The inverse of `ArticlePlayer.utteranceRate(for:)`, because the reader
    /// speaks in Apple's nonlinear 0–1 scale and Kokoro wants "twice as fast".
    /// Going through the utterance rather than around it keeps this class a
    /// drop-in for the system synthesiser.
    static func speed(forUtteranceRate rate: Float) -> Float {
        let normal = AVSpeechUtteranceDefaultSpeechRate
        let multiplier: Float
        if rate == normal {
            multiplier = 1
        } else if rate > normal {
            multiplier = 1 + (rate - 0.5) * 4
        } else {
            multiplier = 1 - (0.5 - rate) / 0.3
        }
        return min(max(multiplier, 0.5), 3)
    }

    /// A chunk as the pieces it will be rendered in: sentences packed up to
    /// the limit, with anything still oversized broken at a word boundary.
    static func segments(of text: String) -> [String] {
        ArticleScript.pieces(of: text, limit: segmentCharacterLimit)
            .flatMap(splitIfOversized)
    }

    private static func splitIfOversized(_ piece: String) -> [String] {
        guard piece.count > hardSegmentCharacterLimit else { return [piece] }
        var pieces: [String] = []
        var current = ""
        for word in piece.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + word.count + 1 <= hardSegmentCharacterLimit {
                current += " " + word
            } else {
                pieces.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
