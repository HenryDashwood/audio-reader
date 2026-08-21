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
    /// A chunk rendered ahead of being asked for, so the reader does not stop
    /// between paragraphs while the next one is made.
    private struct Prefetched {
        let text: String
        let speed: Float
        var segments: [(text: String, audio: KokoroAudio)] = []
    }
    private var prefetched: Prefetched?
    private var prefetchTask: Task<Void, Never>?
    private var pendingPrefetch: (text: String, speed: Float)?

    private var renderedDuration: TimeInterval = 0
    private var renderedCharacters = 0
    private var totalCharacters = 0
    private var isRenderComplete = false

    /// The most text Kokoro can be given in one call before it starts
    /// producing rubbish.
    ///
    /// Not a latency tuning knob — a correctness limit, measured on device.
    /// Above roughly 120 characters this model emits a sustained tone in place
    /// of speech, and the longer the input the more of it there is: a
    /// 261-character paragraph came back as 14.7 seconds of audio containing
    /// **8.9 seconds of a single held note**. It is not the accent, the
    /// punctuation or any particular word — two unrelated paragraphs degrade
    /// identically, and the same input is clean when shortened. It is well
    /// below the 510-token ceiling the library documents.
    ///
    /// Measured longest run of tone, by input length:
    /// 110ch: 0.2s · 120ch: 0.8s · 130ch: 0.8s · 140ch: 1.9s · 150ch: 2.6s ·
    /// 180ch: 3.1s · 240ch: 6.9s
    ///
    /// Synthetic prose survives 110; real article text does not. At 110 the
    /// model dropped whole words on a live article — replacing "From" with a
    /// 310ms buzz, and another word with 890ms of it — which is what the
    /// artefact does: it consumes speech rather than adding noise, so no
    /// filtering can bring the word back. At 90 the buzz does not appear at
    /// all, on any segment of that article. Hence 90, not 110.
    ///
    /// So: keep every call at or under this, and check it again if the model
    /// or the port is ever updated.
    nonisolated static let segmentCharacterLimit = 90
    /// Fallback pace, used only until the first segment has been rendered.
    nonisolated private static let charactersPerSecond = 16.4
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
        reset()

        let id = UtteranceID(utterance)
        let text = utterance.speechString
        // Always rendered at 1x; her chosen speed is applied to the finished
        // audio. Kokoro's own speed control slurs and drops syllables — at
        // 1.5x it swallowed the first syllable of ordinary words — and the
        // model has no idea it is doing it.
        let speed: Float = 1
        output.setRate(Self.speed(forUtteranceRate: utterance.rate))
        let segments = Self.segments(of: text)

        current = id
        totalCharacters = max(text.count, 1)
        isSpeaking = true
        isPaused = false
        output.onDrained = { [weak self] in self?.drained(id) }
        startProgressTimer()

        // Whatever was rendered ahead is a prefix of the segments, so it can
        // be used as far as it goes and the rest rendered from there.
        prefetchTask?.cancel()
        prefetchTask = nil
        var ready: [(text: String, audio: KokoroAudio)] = []
        if let prefetched, prefetched.text == text, prefetched.speed == speed {
            ready = prefetched.segments
        }
        prefetched = nil
        for item in ready { accept(item.audio, characters: item.text.count, for: id) }
        let remaining = Array(segments.dropFirst(ready.count))

        renderTask = Task { [engine, voice] in
            for segment in remaining {
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
    ///
    /// A stop from outside means reading has ended, so the audio engine goes
    /// with it. Moving between chunks goes through `reset()` instead and
    /// leaves the engine up — restarting it there is audible.
    func stopSpeaking(at boundary: AVSpeechBoundary) {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetched = nil
        pendingPrefetch = nil
        reset()
        output.shutDown()
    }

    /// What is coming next, rendered while the current chunk is still playing.
    ///
    /// Nothing starts here: a prefetch that competed with the audio being
    /// played would be exactly the wrong trade. It begins once the chunk in
    /// hand has finished rendering.
    func prepare(_ utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        // Rendered at 1x like everything else, so a change of speed does not
        // throw away what has already been made.
        let speed: Float = 1
        guard !text.isEmpty else { return }
        if let prefetched, prefetched.text == text, prefetched.speed == speed { return }
        pendingPrefetch = (text, speed)
        if isRenderComplete || current == nil { startPrefetch() }
    }

    private func startPrefetch() {
        guard let (text, speed) = pendingPrefetch else { return }
        pendingPrefetch = nil
        prefetchTask?.cancel()
        prefetched = Prefetched(text: text, speed: speed)
        let segments = Self.segments(of: text)
        prefetchTask = Task { [engine, voice] in
            for segment in segments {
                if Task.isCancelled { return }
                guard let audio = try? await engine.render(
                    text: segment, voice: voice, speed: speed)
                else { return }
                if Task.isCancelled { return }
                // Anything else started or stopped in the meantime wins.
                guard self.prefetched?.text == text, self.prefetched?.speed == speed else { return }
                self.prefetched?.segments.append((segment, audio))
            }
        }
    }

    private func reset() {
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
        // Nothing is competing for the engine now, so the next chunk can be
        // made while this one plays.
        startPrefetch()
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
    nonisolated static func speed(forUtteranceRate rate: Float) -> Float {
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
    nonisolated static func segments(of text: String) -> [String] {
        ArticleScript.pieces(of: text, limit: segmentCharacterLimit)
            .flatMap(splitIfOversized)
    }

    /// Sentence packing gets most of the way there, but a single sentence
    /// longer than the limit comes back whole, and has to be broken at a word
    /// boundary rather than handed over intact.
    nonisolated private static func splitIfOversized(_ piece: String) -> [String] {
        guard piece.count > segmentCharacterLimit else { return [piece] }
        var pieces: [String] = []
        var current = ""
        for word in piece.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + word.count + 1 <= segmentCharacterLimit {
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
