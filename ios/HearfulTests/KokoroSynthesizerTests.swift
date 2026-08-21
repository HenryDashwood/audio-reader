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

@Suite("Trimming a rendered segment")
struct KokoroAudioTrimTests {
    private static let rate = 24_000.0
    private var rate: Double { Self.rate }

    /// Silence, then something speech-like, then the decaying low tone the
    /// model leaves behind.
    private static func rendered(
        lead: Double, speech: Double, ring: Double
    ) -> KokoroAudio {
        var samples: [Float] = Array(repeating: 0, count: Int(lead * rate))
        // Speech stands in as noise low-passed to roughly 3kHz. Plain white
        // noise is a poor proxy: it spreads its energy to 12kHz, where speech
        // concentrates it below 4kHz, and that understates the speech-band
        // level the trim actually measures.
        var state: UInt64 = 42
        var smoothed: Float = 0
        for _ in 0..<Int(speech * rate) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
            smoothed += 0.5 * (white - smoothed)
            samples.append(smoothed * 0.6)
        }
        // The ring: a loud low sinusoid, decaying, with no energy in the
        // speech band. Faded in over 20ms because the real one decays out of
        // the speech continuously — a step here would be a broadband click,
        // which any speech detector should and does keep.
        let ringCount = Int(ring * rate)
        let fadeIn = Int(0.02 * rate)
        for index in 0..<ringCount {
            let t = Double(index) / rate
            // Exponential, like the resonance it stands for. A linear ramp
            // stays loud far longer than the real thing and is not a fair test.
            var envelope = exp(-t / 0.12)
            if index < fadeIn { envelope *= Double(index) / Double(fadeIn) }
            samples.append(Float(sin(2 * .pi * 200 * t) * envelope * 0.3))
        }
        return KokoroAudio(samples: samples, sampleRate: rate)
    }

    @Test func theLeadInAndTheRingAreBothRemoved() {
        let audio = Self.rendered(lead: 0.25, speech: 1.0, ring: 0.6)
        let trimmed = audio.trimmedToSpeech()

        #expect(audio.duration > 1.8)
        // The speech survives whole, and most of the 0.85s of junk around it
        // is gone. Not asserted to the millisecond: where exactly the ring
        // falls below the gate depends on how loud it starts.
        #expect(trimmed.duration >= 0.95)
        #expect(trimmed.duration < audio.duration - 0.5)
    }

    @Test func aLoudRingIsNotMistakenForSpeech() {
        // The ring is louder than the speech, so anything gating on loudness
        // alone would keep it. This is why the test is high-frequency energy.
        var audio = Self.rendered(lead: 0.1, speech: 0.8, ring: 0.5)
        audio = KokoroAudio(samples: audio.samples.map { $0 * 1 }, sampleRate: Self.rate)
        let trimmed = audio.trimmedToSpeech()

        #expect(trimmed.duration < audio.duration - 0.3)
    }

    @Test func theBuzzBeforeTheFirstWordIsRemoved() {
        // The artefact that made articles unlistenable: quiet, periodic, with
        // energy only at DC, 4.8kHz and 9.6kHz — and none in the speech band.
        // Over half its energy is above 4kHz, so a high-frequency test keeps
        // it. It has to be found by what it lacks, not what it has.
        var samples: [Float] = []
        let buzz = Int(0.5 * rate)
        for index in 0..<buzz {
            let t = Double(index) / rate
            let value = 0.5 + sin(2 * .pi * 4800 * t) + sin(2 * .pi * 9600 * t)
            samples.append(Float(value) * 0.03)
        }
        var state: UInt64 = 7
        var smoothed: Float = 0
        for _ in 0..<Int(1.0 * rate) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
            smoothed += 0.5 * (white - smoothed)
            samples.append(smoothed * 0.6)
        }
        let audio = KokoroAudio(samples: samples, sampleRate: Self.rate)
        let trimmed = audio.trimmedToSpeech()

        #expect(audio.duration > 1.4)
        #expect(abs(trimmed.duration - 1.0) < 0.15)
    }

    @Test func silenceIsLeftAloneRatherThanEmptied() {
        let silent = KokoroAudio(
            samples: Array(repeating: 0, count: 12_000), sampleRate: Self.rate)

        #expect(silent.trimmedToSpeech().samples.count == silent.samples.count)
    }

    @Test func endsAreFadedSoJoiningSegmentsDoesNotClick() {
        let trimmed = Self.rendered(lead: 0.25, speech: 1.0, ring: 0.6).trimmedToSpeech()

        #expect(abs(trimmed.samples.first ?? 1) < 0.01)
        #expect(abs(trimmed.samples.last ?? 1) < 0.01)
    }
}
