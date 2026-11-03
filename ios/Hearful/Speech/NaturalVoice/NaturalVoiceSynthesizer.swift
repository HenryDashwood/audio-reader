import AVFoundation
import NaturalLanguage
import os

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "natural-voice")

/// Reads articles with the downloadable voice instead of Apple's.
///
/// It stands where SystemSpeechSynthesizer stands: ArticlePlayer hands it an
/// utterance and waits for the same two callbacks. A chunk is rendered a
/// sentence at a time, so the first is heard while the rest are made, and each
/// word is reported as it starts, from where the engine says it lands.
@MainActor
final class NaturalVoiceSynthesizer: SpeechSynthesizing {
    weak var delegate: SpeechSynthesizingDelegate?

    /// Matches AVSpeechSynthesizer: still speaking while paused.
    private(set) var isSpeaking = false
    private(set) var isPaused = false

    private let folder: URL
    private let voice: NaturalVoice
    private let output = NaturalVoiceAudioOutput()
    private var current: UtteranceID?
    private var renderTask: Task<Void, Never>?
    private var progressTimer: Timer?
    /// Each word of what has been queued: its place in the utterance, and in the queued audio.
    private var words: [(characters: NSRange, samples: Range<Int>)] = []
    private var queuedSamples = 0
    private var reported: NSRange?

    init(folder: URL, voice: NaturalVoice) {
        self.folder = folder
        self.voice = voice
    }

    // MARK: - SpeechSynthesizing

    func speak(_ utterance: AVSpeechUtterance) {
        reset()
        let id = UtteranceID(utterance)
        let text = utterance.speechString
        current = id
        isSpeaking = true
        output.setRate(Self.speed(forUtteranceRate: utterance.rate))
        output.onDrained = { [weak self] in self?.finished(id) }
        startProgressTimer()

        let pieces = Self.sentences(in: text)
        let load = Self.engine(folder: folder, voice: voice)
        renderTask = Task { [weak self] in
            do {
                let engine = try await load.value
                for piece in pieces {
                    for (sentence, offset) in try await Self.render(piece.text, at: piece.offset, with: engine) {
                        guard !Task.isCancelled, let self, self.current == id else { return }
                        try self.enqueue(sentence, at: offset)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                log.error("Natural voice could not read a chunk: \(error.localizedDescription, privacy: .public)")
            }
            guard !Task.isCancelled, let self, self.current == id else { return }
            self.output.finishEnqueueing()  // Also after a failure, so the reader moves on rather than stalls
        }
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) {
        reset()
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) {
        guard isSpeaking, !isPaused else { return }
        output.pause()
        isPaused = true
    }

    func continueSpeaking() {
        guard isPaused else { return }
        output.resume()
        isPaused = false
    }

    // MARK: - Rendering

    /// One engine per speaker for the whole app: loading the models takes a moment and most of the memory.
    private static var engines: [NaturalVoice: Task<NaturalVoiceEngine, Error>] = [:]

    static func engine(folder: URL, voice: NaturalVoice) -> Task<NaturalVoiceEngine, Error> {
        if let loading = engines[voice] { return loading }
        let loading = Task.detached(priority: .userInitiated) { try NaturalVoiceEngine(folder: folder, voice: voice) }
        engines = [voice: loading]  // Only one speaker's models in memory at a time
        return loading
    }

    /// The text's sentences, as UTF-16 offsets into it and the text itself.
    ///
    /// NLTokenizer ends a sentence at most full stops, including the ones after "No." and "St.", which would
    /// split "No. 10 Downing St. to St. Paul's" into three and leave each abbreviation without the context that says
    /// how to read it. So a sentence is joined to the next when the next starts with a digit or a lowercase letter, or
    /// when it ends with an abbreviation that usually comes before something.
    nonisolated static func sentences(in text: String) -> [(offset: Int, text: String)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        for range in tokenizer.tokens(for: text.startIndex ..< text.endIndex) {
            if let last = ranges.last, continues(text[last], into: text[range]) {
                ranges[ranges.count - 1] = last.lowerBound ..< range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges.compactMap { range in
            let sentence = String(text[range])
            guard sentence.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return (NSRange(range, in: text).location, sentence)
        }
    }

    nonisolated private static let leadingAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "no", "mt", "ft", "prof", "gen", "gov", "sen", "rep", "rev", "capt", "lt", "col",
        "sgt", "maj", "fr", "fig", "vol", "ch", "pp", "p", "vs", "e.g", "i.e", "cf", "approx", "viz",
    ]

    nonisolated static func continues(_ sentence: Substring, into next: Substring) -> Bool {
        let following = next.drop(while: \.isWhitespace)
        if let first = following.first, first.isNumber || first.isLowercase { return true }
        let lastWord = sentence.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last ?? ""
        guard lastWord.hasSuffix(".") else { return false }
        return leadingAbbreviations.contains(lastWord.dropLast().lowercased())
    }

    /// Renders `text`, splitting it at the best place near the middle, and again, until each part fits the body.
    nonisolated static func render(
        _ text: String, at offset: Int, with engine: NaturalVoiceEngine
    ) async throws -> [(NaturalVoiceEngine.Sentence, Int)] {
        do {
            return [(try await engine.render(text), offset)]
        } catch NaturalVoiceEngine.RenderError.nothingToSay {
            return []
        } catch NaturalVoiceEngine.RenderError.tooLong {
            guard let cut = splitPoint(text) else { throw NaturalVoiceEngine.RenderError.tooLong(frames: 0) }
            let head = String(text[..<cut]), tail = String(text[cut...])
            let tailOffset = offset + (head as NSString).length
            return try await render(head, at: offset, with: engine) + render(tail, at: tailOffset, with: engine)
        }
    }

    /// Where to split an over-long sentence: after the clause punctuation nearest the middle, else the space.
    nonisolated static func splitPoint(_ text: String) -> String.Index? {
        let middle = text.count / 2
        let candidates = text.indices.enumerated().filter { _, i in text[i] == " " && i > text.startIndex }
        let clause = candidates.filter { _, i in ",;:—–".contains(text[text.index(before: i)]) }
        let best = (clause.isEmpty ? candidates : clause).min { abs($0.offset - middle) < abs($1.offset - middle) }
        return best.map { text.index(after: $0.element) }
    }

    private func enqueue(_ sentence: NaturalVoiceEngine.Sentence, at offset: Int) throws {
        for word in sentence.words {
            words.append((
                NSRange(location: offset + word.characters.lowerBound, length: word.characters.count),
                queuedSamples + word.samples.lowerBound ..< queuedSamples + word.samples.upperBound
            ))
        }
        queuedSamples += sentence.samples.count
        try output.enqueue(sentence.samples)
    }

    // MARK: - Progress

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportProgress() }
        }
    }

    private func reportProgress() {
        guard let current, isSpeaking, !isPaused else { return }
        let position = output.position
        guard let word = words.last(where: { $0.samples.lowerBound <= position }), word.characters != reported else {
            return
        }
        reported = word.characters
        delegate?.speechProgressed(to: word.characters, of: current)
    }

    private func finished(_ id: UtteranceID) {
        guard current == id else { return }
        reset()
        delegate?.speechFinished(id)
    }

    private func reset() {
        renderTask?.cancel()
        renderTask = nil
        progressTimer?.invalidate()
        progressTimer = nil
        output.stop()
        current = nil
        words = []
        queuedSamples = 0
        reported = nil
        isSpeaking = false
        isPaused = false
    }

    /// The listener's speed multiplier from ArticlePlayer's utterance rate: the inverse of
    /// `ArticlePlayer.utteranceRate(for:)`.
    nonisolated static func speed(forUtteranceRate rate: Float) -> Float {
        if abs(rate - AVSpeechUtteranceDefaultSpeechRate) < 0.001 { return 1 }
        if rate > 0.5 { return 1 + (rate - 0.5) * 4 }
        return 1 - (0.5 - rate) / 0.3
    }
}
