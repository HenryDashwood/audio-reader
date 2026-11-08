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
    typealias RenderedSentence = (NaturalVoiceEngine.Sentence, Int)
    typealias Renderer = @MainActor (String, Int) async throws -> [RenderedSentence]
    private typealias Rendering = Task<[RenderedSentence], Error>

    weak var delegate: SpeechSynthesizingDelegate?

    /// Matches AVSpeechSynthesizer: still speaking while paused.
    private(set) var isSpeaking = false
    private(set) var isPaused = false

    private let output: any NaturalVoiceOutput
    private let renderSentence: Renderer
    private var current: UtteranceID?
    private var renderTask: Task<Void, Never>?
    private var progressTimer: Timer?
    /// Each word of what has been queued: its place in the utterance, and in the queued audio.
    private var words: [(characters: NSRange, samples: Range<Int>)] = []
    private var queuedSamples = 0
    private var reported: NSRange?
    /// Render one chunk ahead while the current audio plays. Preparing only
    /// its first sentence leaves too little time to render a long second
    /// sentence after a short first one, especially on a model size's first use.
    private var nextText: String?
    private var prepared: (text: String, sentences: [Rendering])?
    private var activePreparation: [Rendering] = []
    private var renderedCurrent = false
    private var paragraphPauseSamples = 0
    /// How long queued speech may sit without the clock moving before the
    /// output is taken to be dead. Generous: a healthy engine moves every render.
    private let stallLimit: Duration
    private var stalledSince: ContinuousClock.Instant?
    /// How long she may hear nothing while the chunk is still being rendered.
    /// A sentence renders in well under a second normally and a few seconds on
    /// a cold model in the background; this long means a render has hung.
    private let renderLimit: Duration
    private var starvedSince: ContinuousClock.Instant?
    private var lastPosition = 0
    /// Added to the model's normal sentence spacing, at the rendered 1× rate.
    static let additionalParagraphPause: TimeInterval = 0.2

    init(
        folder: URL, voice: NaturalVoice,
        output: (any NaturalVoiceOutput)? = nil, renderSentence: Renderer? = nil,
        stallLimit: Duration = .seconds(4), renderLimit: Duration = .seconds(20)
    ) {
        self.output = output ?? NaturalVoiceAudioOutput()
        self.stallLimit = stallLimit
        self.renderLimit = renderLimit
        self.renderSentence = renderSentence ?? { text, offset in
            let engine = try await Self.engine(folder: folder, voice: voice).value
            return try await Self.render(text, at: offset, with: engine)
        }
        Self.instances.add(self)
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
        output.onFailure = { [weak self] in self?.failed(id) }
        startProgressTimer()
        Self.activityChanged()

        let pieces = Self.sentences(in: text)
        let ready = prepared?.text == text ? prepared?.sentences : nil
        if ready == nil { cancelPreparation() }
        activePreparation = ready ?? []
        prepared = nil
        nextText = nil
        renderedCurrent = false
        renderTask = Task { [weak self, renderSentence] in
            do {
                for (index, piece) in pieces.enumerated() {
                    let rendered = if let ready {
                        try await ready[index].value
                    } else {
                        try await renderSentence(piece.text, piece.offset)
                    }
                    for (sentence, offset) in rendered {
                        guard !Task.isCancelled, let self, self.current == id else { return }
                        try self.enqueue(sentence, at: offset)
                    }
                }
                if !Task.isCancelled, let self, self.current == id, self.paragraphPauseSamples > 0 {
                    // Queue silence with the speech so pause, resume and speed
                    // changes apply to it without a separate timer or state change.
                    try self.enqueue(
                        NaturalVoiceEngine.Sentence(
                            samples: [Float](repeating: 0, count: self.paragraphPauseSamples), words: []),
                        at: 0)
                }
            } catch is CancellationError {
                return
            } catch {
                log.error("Natural voice could not read a chunk: \(error.localizedDescription, privacy: .public)")
                // Not finishEnqueueing: that ended the chunk early, and with the
                // screen locked a run of failures skipped passage after passage
                // in silence. The reader restarts it, then uses the system voice.
                guard !Task.isCancelled, let self, self.current == id else { return }
                self.failed(id)
                return
            }
            guard !Task.isCancelled, let self, self.current == id else { return }
            self.renderedCurrent = true
            self.prepareNext()
            // May synchronously finish this chunk and start another one.
            self.output.finishEnqueueing()
        }
    }

    func prepare(_ text: String) {
        prepare(text, startsNewParagraph: false)
    }

    func prepare(_ text: String, startsNewParagraph: Bool) {
        nextText = text
        paragraphPauseSamples = startsNewParagraph
            ? Int(Self.additionalParagraphPause * NaturalVoiceEngine.sampleRate) : 0
        if renderedCurrent { prepareNext() }
    }

    /// Start each sentence in order, after the current chunk is rendered.
    /// Separate tasks let playback consume the first ready sentence without
    /// waiting for the rest of the preparation to finish.
    private func prepareNext() {
        guard let text = nextText, prepared?.text != text else { return }
        cancelPreparation()
        var previous: Rendering?
        let sentences = Self.sentences(in: text).map { piece in
            let before = previous
            let rendering = Task { [renderSentence] in
                if let before { _ = try await before.value }
                try Task.checkCancellation()
                return try await renderSentence(piece.text, piece.offset)
            }
            previous = rendering
            return rendering
        }
        prepared = (text, sentences)
    }

    private func cancelPreparation() {
        prepared?.sentences.forEach { $0.cancel() }
        prepared = nil
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) {
        reset()
        cancelPreparation()
    }

    @discardableResult func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        guard isSpeaking, !isPaused else { return false }
        output.pause()
        isPaused = true
        Self.activityChanged()
        return true
    }

    func continueSpeaking() {
        guard isPaused else { return }
        isPaused = false
        Self.activityChanged()
        output.resume()  // May report a failure at once if the engine died while paused
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

    /// Lets the models go: the voice was removed, or its files are about to change.
    static func releaseEngines() {
        engines = [:]
    }

    /// Five minutes without reading anything frees the models; see NaturalVoiceIdleRelease.
    private static let idleRelease = NaturalVoiceIdleRelease(after: .seconds(300)) {
        guard !engines.isEmpty else { return }
        log.info("Natural voice idle; releasing its models")
        releaseEngines()
    }
    private static let instances = NSHashTable<NaturalVoiceSynthesizer>.weakObjects()

    /// Restarts the idle countdown, or stops it while any synthesiser is reading. Paused doesn't count as reading.
    static func activityChanged() {
        idleRelease.update(busy: instances.allObjects.contains { $0.isSpeaking && !$0.isPaused })
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
            // Each half must be strictly shorter, or the recursion never ends.
            guard head.count < text.count, tail.count < text.count else {
                throw NaturalVoiceEngine.RenderError.tooLong(frames: 0)
            }
            let tailOffset = offset + (head as NSString).length
            return try await render(head, at: offset, with: engine) + render(tail, at: tailOffset, with: engine)
        }
    }

    /// Where to split an over-long sentence: after the clause punctuation nearest the middle, else the space.
    ///
    /// Only a space with something to say on both sides counts. A first half
    /// keeps the space it was cut after, so "…accurate predictions, " ends in
    /// one: choosing it again split the half into itself and nothing, and the
    /// voice rendered the same 198 characters for ever, ten times a second.
    nonisolated static func splitPoint(_ text: String) -> String.Index? {
        let middle = text.count / 2
        let speaks: (Substring) -> Bool = { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        let candidates = text.indices.enumerated().filter { _, i in
            text[i] == " " && i > text.startIndex && speaks(text[..<i]) && speaks(text[text.index(after: i)...])
        }
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
        try output.enqueue(sentence.samples, continuesToNextChunk: nextText != nil)
    }

    // MARK: - Progress

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportProgress() }
        }
    }

    private func reportProgress() {
        guard let current, isSpeaking, !isPaused else {
            stalledSince = nil
            starvedSince = nil
            return
        }
        let position = output.position
        if detectStall(at: position) || detectStarvation() { return }
        guard let word = words.last(where: { $0.samples.lowerBound <= position }), word.characters != reported else {
            return
        }
        reported = word.characters
        delegate?.speechProgressed(to: word.characters, of: current)
    }

    /// Speech queued, nothing holding it, and the clock stuck: the engine has
    /// gone without saying so. Without this the reader stayed "playing" in
    /// silence for ever, the lock screen's clock running on regardless.
    private func detectStall(at position: Int) -> Bool {
        guard output.isExpectingSound, position == lastPosition else {
            lastPosition = position
            stalledSince = nil
            return false
        }
        let now = ContinuousClock.now
        guard let since = stalledSince else {
            stalledSince = now
            return false
        }
        guard now - since >= stallLimit, let current else { return false }
        log.error("Natural voice output stalled at sample \(position, privacy: .public)")
        failed(current)
        return true
    }

    /// Nothing left to play and the chunk still not rendered, for far longer
    /// than a render takes: the engine is stuck inside one. Its actor stays
    /// blocked behind that call, so the next synthesiser needs a new engine.
    private func detectStarvation() -> Bool {
        guard !renderedCurrent, !output.isExpectingSound else {
            starvedSince = nil
            return false
        }
        let now = ContinuousClock.now
        guard let since = starvedSince else {
            starvedSince = now
            return false
        }
        guard now - since >= renderLimit, let current else { return false }
        log.error("Natural voice rendering made no progress for \(self.renderLimit, privacy: .public); replacing the engine")
        Self.releaseEngines()
        failed(current)
        return true
    }

    private func failed(_ id: UtteranceID) {
        guard current == id else { return }
        reset()
        delegate?.speechFailed(id)
    }

    private func finished(_ id: UtteranceID) {
        guard current == id else { return }
        reset()
        delegate?.speechFinished(id)
    }

    private func reset() {
        renderTask?.cancel()
        renderTask = nil
        activePreparation.forEach { $0.cancel() }
        activePreparation = []
        nextText = nil
        renderedCurrent = false
        paragraphPauseSamples = 0
        progressTimer?.invalidate()
        progressTimer = nil
        output.stop()
        current = nil
        words = []
        queuedSamples = 0
        reported = nil
        stalledSince = nil
        starvedSince = nil
        lastPosition = 0
        isSpeaking = false
        isPaused = false
        Self.activityChanged()
    }

    /// The listener's speed multiplier from ArticlePlayer's utterance rate: the inverse of
    /// `ArticlePlayer.utteranceRate(for:)`.
    nonisolated static func speed(forUtteranceRate rate: Float) -> Float {
        if abs(rate - AVSpeechUtteranceDefaultSpeechRate) < 0.001 { return 1 }
        if rate > 0.5 { return 1 + (rate - 0.5) * 4 }
        return 1 - (0.5 - rate) / 0.3
    }
}
