import AVFoundation
import Foundation
import Testing

@testable import Hearful

/// An engine that renders instantly and silently, so the reader's side of the
/// arrangement can be exercised without MLX, model files or a GPU.
private actor FakeKokoroEngine: KokoroRendering {
    private let failing: Bool
    private(set) var renderedSegments: [String] = []
    private(set) var speeds: [Float] = []

    nonisolated static let sampleRate = 24_000.0
    /// Enough that a longer segment really is longer.
    nonisolated static let secondsPerCharacter = 0.05

    init(failing: Bool = false) {
        self.failing = failing
    }

    func availableVoices() async -> [KokoroVoice] { KokoroVoice.catalogue }

    func render(text: String, voice: KokoroVoice, speed: Float) async throws -> KokoroAudio {
        renderedSegments.append(text)
        speeds.append(speed)
        if failing { throw KokoroEngineError.voiceMissing(voice.name) }
        let frames = Int(Double(text.count) * Self.secondsPerCharacter * Self.sampleRate)
        return KokoroAudio(
            samples: [Float](repeating: 0, count: frames), sampleRate: Self.sampleRate)
    }
}

/// An output that keeps what it was given and never makes a sound.
@MainActor
private final class FakeKokoroOutput: KokoroAudioOutputting {
    var onDrained: (@MainActor () -> Void)?
    var elapsed: TimeInterval = 0

    private(set) var enqueued: [KokoroAudio] = []
    private(set) var isFinished = false
    private(set) var isPaused = false
    private(set) var stops = 0

    func enqueue(_ audio: KokoroAudio) { enqueued.append(audio) }
    func finishEnqueueing() { isFinished = true }
    func pause() { isPaused = true }
    func resume() { isPaused = false }

    private(set) var shutDowns = 0

    func shutDown() {
        shutDowns += 1
        stop()
    }

    func stop() {
        stops += 1
        onDrained = nil
        enqueued = []
        isFinished = false
    }

    /// Forgets what it was given, without counting as a stop.
    func reset() {
        enqueued = []
        isFinished = false
    }

    /// The queue playing itself out, which is what ends an utterance.
    func drain() {
        let finished = onDrained
        onDrained = nil
        finished?()
    }
}

@MainActor
private final class SpyDelegate: SpeechSynthesizingDelegate {
    private(set) var finished: [UtteranceID] = []
    private(set) var fractions: [Double] = []

    func speechFinished(_ utterance: UtteranceID) { finished.append(utterance) }

    func speechProgressed(toFraction fraction: Double, of utterance: UtteranceID) {
        fractions.append(fraction)
    }
}

@MainActor
@Suite("Kokoro synthesiser")
struct KokoroSynthesizerTests {
    private static let voice = KokoroVoice(name: "bf_emma", displayName: "Emma (UK)")

    private func waitUntilRendered(_ engine: FakeKokoroEngine, atLeast count: Int) async -> Bool {
        for _ in 0..<200 {
            if await engine.renderedSegments.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await engine.renderedSegments.count >= count
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: - Standing in for the system synthesiser

    @Test func theReadersRateBecomesASpeedMultiplier() {
        // The reader speaks Apple's nonlinear 0–1 scale; Kokoro wants "twice
        // as fast". Every step she can choose has to survive the round trip.
        for multiplier in [Float(0.75), 1, 1.5, 2] {
            let rate = ArticlePlayer.utteranceRate(for: multiplier)
            let recovered = KokoroSynthesizer.speed(forUtteranceRate: rate)
            #expect(abs(recovered - multiplier) < 0.01)
        }
    }

    @Test func theFastestSettingSaturatesRatherThanInverting() {
        // ArticlePlayer caps the utterance rate below what 3× would need, so
        // the fastest setting comes back a little slower. Worth knowing about
        // rather than discovering in the voice.
        let recovered = KokoroSynthesizer.speed(forUtteranceRate: ArticlePlayer.utteranceRate(for: 3))
        #expect(recovered > 2.5)
        #expect(recovered <= 3)
    }

    // MARK: - Splitting

    @Test func chunksAreSplitSoTheFirstWordsArriveQuickly() {
        let sentence = "This sentence is repeated until the paragraph is far too long to render. "
        let segments = KokoroSynthesizer.segments(of: String(repeating: sentence, count: 8))

        #expect(segments.count > 1)
        #expect(segments.allSatisfy { $0.count <= KokoroSynthesizer.segmentCharacterLimit })
        // Splitting must never lose words.
        let words = segments.flatMap { $0.split(separator: " ") }.count
        #expect(words == 8 * sentence.split(separator: " ").count)
    }

    @Test func oneLongSentenceIsBrokenAtAWordBoundary() {
        // No full stops at all: the sentence tokeniser cannot help, and the
        // fallback is what keeps Kokoro inside its token ceiling.
        let runOn = String(repeating: "word ", count: 200)
        let segments = KokoroSynthesizer.segments(of: runOn)

        #expect(segments.count > 1)
        #expect(segments.allSatisfy { $0.count <= KokoroSynthesizer.segmentCharacterLimit })
        #expect(segments.allSatisfy { !$0.contains("wordword") })
    }

    // MARK: - Speaking

    @Test func everySegmentIsRenderedAndQueued() async {
        let engine = FakeKokoroEngine()
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(engine: engine, voice: Self.voice, output: output)
        let sentence = "A sentence that will be one segment among several here. "
        let text = String(repeating: sentence, count: 6)

        synthesizer.speak(AVSpeechUtterance(string: text))
        #expect(await waitUntil { output.isFinished })

        let expected = KokoroSynthesizer.segments(of: text)
        let rendered = await engine.renderedSegments
        #expect(rendered == expected)
        #expect(output.enqueued.count == expected.count)
    }

    @Test func theChunkEndsOnlyWhenTheAudioHasBeenPlayed() async {
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(engine: FakeKokoroEngine(), voice: Self.voice, output: output)
        let delegate = SpyDelegate()
        synthesizer.delegate = delegate
        let utterance = AVSpeechUtterance(string: "Something short to say.")

        synthesizer.speak(utterance)
        #expect(await waitUntil { output.isFinished })
        // Rendered, but not yet heard: the reader must not advance.
        #expect(delegate.finished.isEmpty)
        #expect(synthesizer.isSpeaking)

        output.drain()
        #expect(delegate.finished == [UtteranceID(utterance)])
        #expect(!synthesizer.isSpeaking)
    }

    @Test func progressFollowsThePlayheadThroughTheChunk() async {
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(engine: FakeKokoroEngine(), voice: Self.voice, output: output)
        let text = String(repeating: "Some words to fill the chunk out. ", count: 4)

        synthesizer.speak(AVSpeechUtterance(string: text))
        #expect(await waitUntil { output.isFinished })

        let total = output.enqueued.reduce(0) { $0 + $1.duration }
        #expect(total > 0)
        output.elapsed = 0
        #expect(synthesizer.fraction == 0)
        output.elapsed = total / 2
        #expect(abs(synthesizer.fraction - 0.5) < 0.01)
        // Never past the end, however long the buffer overruns the estimate.
        output.elapsed = total * 2
        #expect(synthesizer.fraction == 1)
    }

    @Test func aDeliberateStopFinishesNothing() async {
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(engine: FakeKokoroEngine(), voice: Self.voice, output: output)
        let delegate = SpyDelegate()
        synthesizer.delegate = delegate

        synthesizer.speak(AVSpeechUtterance(string: "Something she changed her mind about."))
        synthesizer.stopSpeaking(at: .immediate)
        output.drain()

        #expect(output.stops >= 1)
        #expect(delegate.finished.isEmpty)
        #expect(!synthesizer.isSpeaking)
    }

    @Test func aFailedRenderStillReleasesTheChunk() async {
        // A voice that will not render must not strand the article on one
        // paragraph in silence.
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(
            engine: FakeKokoroEngine(failing: true), voice: Self.voice, output: output)
        let delegate = SpyDelegate()
        synthesizer.delegate = delegate
        let utterance = AVSpeechUtterance(string: "Anything at all.")

        synthesizer.speak(utterance)

        #expect(await waitUntil { !delegate.finished.isEmpty })
        #expect(delegate.finished == [UtteranceID(utterance)])
    }

    @Test func whatWasPreparedIsNotRenderedAgain() async {
        // The point of preparing: by the time the reader asks for the next
        // chunk the audio already exists, so there is no silence at the
        // paragraph break while it is made.
        let engine = FakeKokoroEngine()
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(engine: engine, voice: Self.voice, output: output)
        let current = "The paragraph being read aloud right now, at some length."
        let next = "The paragraph that comes after the one being read aloud."
        let expected = KokoroSynthesizer.segments(of: next)
        let all = KokoroSynthesizer.segments(of: current).count + expected.count

        synthesizer.speak(AVSpeechUtterance(string: current))
        #expect(await waitUntil { output.isFinished })
        synthesizer.prepare(AVSpeechUtterance(string: next))
        #expect(await waitUntilRendered(engine, atLeast: all))

        let renderedBefore = await engine.renderedSegments.count
        output.reset()
        synthesizer.speak(AVSpeechUtterance(string: next))
        #expect(await waitUntil { output.isFinished })

        // Nothing new was rendered, and all of it still reached the speaker.
        let renderedAfter = await engine.renderedSegments.count
        #expect(renderedAfter == renderedBefore)
        #expect(output.enqueued.count == expected.count)
    }

    @Test func aDeliberateStopGivesTheAudioSessionBack() async {
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(engine: FakeKokoroEngine(), voice: Self.voice, output: output)

        synthesizer.speak(AVSpeechUtterance(string: "Something being read."))
        // Moving between chunks must not tear the engine down: doing that
        // between every chunk is audible.
        synthesizer.speak(AVSpeechUtterance(string: "The next chunk."))
        #expect(output.shutDowns == 0)

        synthesizer.stopSpeaking(at: .immediate)
        #expect(output.shutDowns == 1)
    }

    @Test func pausingKeepsTheUtteranceButStopsTheSound() async {
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(engine: FakeKokoroEngine(), voice: Self.voice, output: output)

        synthesizer.speak(AVSpeechUtterance(string: "Something to interrupt."))
        synthesizer.pauseSpeaking(at: .immediate)

        #expect(output.isPaused)
        #expect(synthesizer.isPaused)
        // Matches AVSpeechSynthesizer: paused is still speaking.
        #expect(synthesizer.isSpeaking)

        synthesizer.continueSpeaking()
        #expect(!output.isPaused)
        #expect(!synthesizer.isPaused)
    }
}

@Suite("Kokoro voices")
struct KokoroVoiceTests {
    @Test func identifiersRoundTripAndCannotBeConfusedWithApples() {
        let voice = KokoroVoice.catalogue[0]

        #expect(voice.identifier.hasPrefix("kokoro:"))
        #expect(KokoroVoice.name(fromIdentifier: voice.identifier) == voice.name)
        #expect(KokoroVoice.named(voice.name) == voice)
        // An AVSpeechSynthesisVoice identifier must never resolve here.
        #expect(KokoroVoice.name(fromIdentifier: "com.apple.voice.premium.en-GB.Serena") == nil)
    }

    @Test func accentDecidesThePronunciationRules() {
        #expect(KokoroVoice.catalogue.contains { $0.isBritish })
        #expect(KokoroVoice.catalogue.contains { !$0.isBritish })
        #expect(KokoroVoice(name: "bf_emma", displayName: "Emma").isBritish)
        #expect(!KokoroVoice(name: "af_heart", displayName: "Heart").isBritish)
    }
}
