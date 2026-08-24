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

/// A renderer whose caller decides when each segment becomes available. That
/// makes the buffering boundary deterministic instead of relying on sleeps.
private actor GatedKokoroEngine: KokoroRendering {
    private var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedSegments = 0

    func availableVoices() async -> [KokoroVoice] { KokoroVoice.catalogue }

    func render(text: String, voice: KokoroVoice, speed: Float) async throws -> KokoroAudio {
        requestedSegments += 1
        await withCheckedContinuation { continuation in
            gates.append(continuation)
        }
        let sampleRate = 100.0
        let frames = Int(Double(text.count) * FakeKokoroEngine.secondsPerCharacter * sampleRate)
        return KokoroAudio(samples: [Float](repeating: 0, count: frames), sampleRate: sampleRate)
    }

    func releaseNext() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }
}

/// An output that keeps what it was given and never makes a sound.
@MainActor
private final class FakeKokoroOutput: KokoroAudioOutputting {
    var onDrained: (@MainActor () -> Void)?
    var onUnderrun: (@MainActor () -> Void)?
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
    private(set) var rate: Float = 1

    func setRate(_ rate: Float) { self.rate = rate }

    func shutDown() {
        shutDowns += 1
        stop()
    }

    func stop() {
        stops += 1
        onDrained = nil
        onUnderrun = nil
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

    func underrun() {
        onUnderrun?()
    }
}

@MainActor
private final class SpyDelegate: SpeechSynthesizingDelegate {
    private(set) var finished: [UtteranceID] = []
    private(set) var failed: [UtteranceID] = []
    private(set) var fractions: [Double] = []

    func speechFinished(_ utterance: UtteranceID) { finished.append(utterance) }
    func speechFailed(_ utterance: UtteranceID) { failed.append(utterance) }

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

    private func waitUntilRequested(_ engine: GatedKokoroEngine, atLeast count: Int) async -> Bool {
        for _ in 0..<200 {
            if await engine.requestedSegments >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await engine.requestedSegments >= count
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

    @Test func speedIsAppliedToThePlaybackNotTheModel() async {
        // Kokoro's own speed control slurs; stretching finished audio does
        // not. So the render is always 1x and the rate goes to the output.
        let engine = FakeKokoroEngine()
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(engine: engine, voice: Self.voice, output: output)
        let utterance = AVSpeechUtterance(string: "Something read quickly.")
        utterance.rate = ArticlePlayer.utteranceRate(for: 2)

        synthesizer.speak(utterance)
        #expect(await waitUntil { output.isFinished })

        let speeds = await engine.speeds
        #expect(speeds.allSatisfy { $0 == 1 })
        #expect(abs(output.rate - 2) < 0.01)
    }

    @Test func fastPlaybackBuildsMoreReserveThanNormalPlayback() {
        #expect(KokoroSynthesizer.startupBufferDuration(forPlaybackRate: 1) == 0)
        #expect(KokoroSynthesizer.startupBufferDuration(forPlaybackRate: 1.5) == 2.5)
        #expect(KokoroSynthesizer.startupBufferDuration(forPlaybackRate: 2) == 3)
        #expect(KokoroSynthesizer.startupBufferDuration(forPlaybackRate: 3) == 4)
    }

    @Test func fastPlaybackBuildsAReserveAtStartupAndAfterAnUnderrun() async throws {
        let engine = GatedKokoroEngine()
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(engine: engine, voice: Self.voice, output: output)
        let sentence =
            "This deliberately measured sentence fills one render buffer without being too long. "
        let text = String(repeating: sentence, count: 6)
        let segments = KokoroSynthesizer.segments(of: text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = ArticlePlayer.utteranceRate(for: 2)

        let target = KokoroSynthesizer.startupBufferDuration(forPlaybackRate: 2)
        var sourceDuration = 0.0
        let lastBufferedIndex = try #require(segments.indices.first { index in
            sourceDuration += Double(segments[index].count) * FakeKokoroEngine.secondsPerCharacter
            return sourceDuration / 2 >= target
        })
        let segmentsNeeded = lastBufferedIndex + 1
        #expect(segmentsNeeded > 1)
        #expect(segments.count >= segmentsNeeded * 2)

        synthesizer.speak(utterance)
        for index in 0..<segmentsNeeded {
            #expect(await waitUntilRequested(engine, atLeast: index + 1))
            await engine.releaseNext()
            if index + 1 < segmentsNeeded {
                #expect(await waitUntilRequested(engine, atLeast: index + 2))
                #expect(output.enqueued.isEmpty)
            }
        }
        #expect(await waitUntil { output.enqueued.count == segmentsNeeded })

        // Once playback catches the renderer, one newly rendered segment is
        // held rather than played as an isolated burst. The same target is
        // rebuilt before output resumes.
        #expect(await waitUntilRequested(engine, atLeast: segmentsNeeded + 1))
        output.underrun()
        let enqueuedBeforeUnderrun = output.enqueued.count
        for offset in 0..<segmentsNeeded {
            let index = segmentsNeeded + offset
            await engine.releaseNext()
            if offset + 1 < segmentsNeeded {
                #expect(await waitUntilRequested(engine, atLeast: index + 2))
                #expect(output.enqueued.count == enqueuedBeforeUnderrun)
            }
        }
        #expect(await waitUntil {
            output.enqueued.count == enqueuedBeforeUnderrun + segmentsNeeded
        })

        for index in (segmentsNeeded * 2)..<segments.count {
            #expect(await waitUntilRequested(engine, atLeast: index + 1))
            await engine.releaseNext()
        }
        #expect(await waitUntil { output.isFinished })
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

    @Test func oneLongSentencePrefersAClauseBoundary() {
        let text =
            "Although the opening clause has enough words to make a useful and natural boundary, "
            + "the sentence continues beyond the model's safe rendering limit without ending yet."
        let segments = KokoroSynthesizer.segments(of: text)

        #expect(segments.count == 2)
        #expect(segments[0].hasSuffix(","))
        #expect(segments.joined(separator: " ") == text)
        #expect(segments.allSatisfy { $0.count <= KokoroSynthesizer.segmentCharacterLimit })
    }

    @Test func unbrokenTextStillObeysTheModelsLimit() {
        let text = String(repeating: "x", count: KokoroSynthesizer.segmentCharacterLimit * 2 + 1)
        let segments = KokoroSynthesizer.segments(of: text)

        #expect(segments.map(\.count) == [
            KokoroSynthesizer.segmentCharacterLimit,
            KokoroSynthesizer.segmentCharacterLimit,
            1,
        ])
        #expect(segments.joined() == text)
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

    @Test func aFailedRenderDoesNotPretendTheChunkWasSpoken() async {
        // The reader needs a failure callback so it can retry this exact text
        // with the system voice rather than silently advancing past it.
        let output = FakeKokoroOutput()
        let synthesizer = KokoroSynthesizer(
            engine: FakeKokoroEngine(failing: true), voice: Self.voice, output: output)
        let delegate = SpyDelegate()
        synthesizer.delegate = delegate
        let utterance = AVSpeechUtterance(string: "Anything at all.")

        synthesizer.speak(utterance)

        #expect(await waitUntil { !delegate.failed.isEmpty })
        #expect(delegate.failed == [UtteranceID(utterance)])
        #expect(delegate.finished.isEmpty)
        #expect(output.shutDowns == 1)
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

@Suite("Kokoro text normalisation")
struct KokoroTextNormalizationTests {
    @Test func lowercaseIndefiniteArticlesAreExplicitlyReduced() {
        let text =
            "Everyone knows what a Cyclops looks like. From a child’s first encounter "
            + "with Greek mythology, it becomes a memorable image."

        #expect(
            KokoroTextNormalization.forSynthesis(text)
                == "Everyone knows what [a](/ɐ/) Cyclops looks like. "
                + "From [a](/ɐ/) child’s first encounter with Greek mythology, "
                + "it becomes [a](/ɐ/) memorable image."
        )
    }

    @Test func lettersAbbreviationsAndCharactersInsideWordsAreUntouched() {
        let text = "Plan A uses data at 9 a.m.; compare option a. Then a child follows."

        #expect(
            KokoroTextNormalization.forSynthesis(text)
                == "Plan A uses data at 9 a.m.; compare option a. Then [a](/ɐ/) child follows."
        )
    }

    @Test func openingPunctuationCanBeginTheFollowingNounPhrase() {
        #expect(
            KokoroTextNormalization.forSynthesis("It resembles a “Cyclops” in profile.")
                == "It resembles [a](/ɐ/) “Cyclops” in profile."
        )
    }
}

@Suite("Trimming a rendered segment")
struct KokoroAudioTrimTests {
    private static let rate = 24_000.0

    /// A render as the model delivers it: silence, speech, silence.
    private static func rendered(
        lead: Double, speech: Double, trail: Double
    ) -> KokoroAudio {
        var samples: [Float] = Array(repeating: 0, count: Int(lead * rate))
        var state: UInt64 = 42
        var smoothed: Float = 0
        for _ in 0..<Int(speech * rate) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
            smoothed += 0.5 * (white - smoothed)
            samples.append(smoothed * 0.6)
        }
        samples.append(contentsOf: Array(repeating: 0, count: Int(trail * rate)))
        return KokoroAudio(samples: samples, sampleRate: rate)
    }

    @Test func theSilenceEitherSideIsRemoved() {
        // What the model actually leaves: ~0.29s before, ~0.68s after. Joined
        // segment to segment that is a second of dead air at every paragraph.
        let audio = Self.rendered(lead: 0.29, speech: 1.0, trail: 0.68)
        let trimmed = audio.trimmedSilence()

        #expect(abs(trimmed.duration - 1.04) < 0.03)  // the speech, plus 20ms margin either side
    }

    @Test func nothingAudibleIsEverRemoved() {
        // The failure this replaced: a speech classifier clipped word-initial
        // sibilants and faded the first syllable. A silence trim cannot,
        // because it only ever cuts what is already below hearing.
        let audio = Self.rendered(lead: 0.29, speech: 1.0, trail: 0.68)
        let trimmed = audio.trimmedSilence()

        let loudBefore = audio.samples.filter { abs($0) > 0.002 }
        let loudAfter = trimmed.samples.filter { abs($0) > 0.002 }
        #expect(loudAfter == loudBefore)
    }

    @Test func theEdgesAreNotFadedSoOnsetsSurvive() {
        // A fade at the cut is what made "Everyone" sound rushed.
        let trimmed = Self.rendered(lead: 0.29, speech: 1.0, trail: 0.68).trimmedSilence()
        let margin = Int(0.02 * Self.rate)

        // The first audible sample is untouched, not ramped.
        let firstAudible = trimmed.samples[margin...].first { abs($0) > 0.002 }
        #expect(firstAudible != nil)
    }

    @Test func silenceIsLeftAloneRatherThanEmptied() {
        let silent = KokoroAudio(
            samples: Array(repeating: 0, count: 12_000), sampleRate: Self.rate)

        #expect(silent.trimmedSilence().samples.count == silent.samples.count)
    }

    @Test func audioWithNoSilenceIsUntouched() {
        let audio = Self.rendered(lead: 0, speech: 1.0, trail: 0)
        let trimmed = audio.trimmedSilence()

        #expect(trimmed.samples.count == audio.samples.count)
    }
}
