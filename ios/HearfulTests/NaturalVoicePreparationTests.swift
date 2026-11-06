import AVFoundation
import Foundation
import Testing

@testable import Hearful

@Suite("Natural voice prepares upcoming sentences")
@MainActor
struct NaturalVoicePreparationTests {
    private final class Output: NaturalVoiceOutput {
        var onDrained: (@MainActor () -> Void)?
        var onFailure: (@MainActor () -> Void)?
        var position = 0
        var isExpectingSound = false
        var enqueued: [Float] = []
        var continuingBuffers: [Bool] = []
        var completedChunks = 0
        func setRate(_ rate: Float) {}
        func enqueue(_ samples: [Float], continuesToNextChunk: Bool) {
            enqueued += samples
            continuingBuffers.append(continuesToNextChunk)
        }
        func finishEnqueueing() { completedChunks += 1 }
        func pause() {}
        func resume() {}
        func stop() {
            onDrained = nil
            onFailure = nil
        }
        func drain() {
            let finished = onDrained
            onDrained = nil
            finished?()
        }
    }

    private final class Renderer {
        let delay = ControlledDelay()
        var heldSentence: String?
        var requested: [String] = []
        var completed: [String] = []

        func render(_ text: String, at offset: Int) async throws -> [NaturalVoiceSynthesizer.RenderedSentence] {
            requested.append(text)
            let sample = Float(requested.count)
            if text == heldSentence { try await delay.wait(for: .seconds(30)) }
            try Task.checkCancellation()
            completed.append(text)
            return [(NaturalVoiceEngine.Sentence(samples: [sample], words: []), offset)]
        }
    }

    private final class Listener: SpeechSynthesizingDelegate {
        var failed: [UtteranceID] = []
        var finished: [UtteranceID] = []
        func speechFinished(_ utterance: UtteranceID) { finished.append(utterance) }
        func speechProgressed(to range: NSRange, of utterance: UtteranceID) {}
        func speechFailed(_ utterance: UtteranceID) { failed.append(utterance) }
    }

    private func synthesizer(
        output: Output, renderer: Renderer, stallLimit: Duration = .seconds(4),
        renderLimit: Duration = .seconds(20)
    ) -> NaturalVoiceSynthesizer {
        NaturalVoiceSynthesizer(
            folder: URL.temporaryDirectory, voice: NaturalVoice(id: "bf_emma"),
            output: output, renderSentence: renderer.render, stallLimit: stallLimit,
            renderLimit: renderLimit)
    }

    @Test func aRenderThatNeverReturnsIsReportedAsFailedOnceTheQueuedAudioRunsOut() async throws {
        let output = Output()
        let renderer = Renderer()
        let synth = synthesizer(output: output, renderer: renderer, renderLimit: .milliseconds(300))
        defer { synth.stopSpeaking(at: .immediate) }
        let listener = Listener()
        synth.delegate = listener
        let utterance = AVSpeechUtterance(string: "These do not bug me that much. But this one hangs.")
        renderer.heldSentence = NaturalVoiceSynthesizer.sentences(in: utterance.speechString).last?.text

        synth.speak(utterance)
        try await waitUntil { output.enqueued.count == 1 && renderer.delay.pendingCount == 1 }
        // The first sentence is still playing: waiting on the next is fine.
        output.isExpectingSound = true
        try await Task.sleep(for: .milliseconds(500))
        #expect(listener.failed.isEmpty)

        output.isExpectingSound = false  // Played out; nothing left to say
        try await waitUntil { listener.failed == [UtteranceID(utterance)] }
        #expect(listener.finished.isEmpty)
        #expect(!synth.isSpeaking)
    }

    @Test func queuedSpeechWhoseClockStopsIsReportedAsFailed() async throws {
        let output = Output()
        let synth = synthesizer(output: output, renderer: Renderer(), stallLimit: .milliseconds(200))
        defer { synth.stopSpeaking(at: .immediate) }
        let listener = Listener()
        synth.delegate = listener
        let utterance = AVSpeechUtterance(string: "The engine dies under this sentence.")

        synth.speak(utterance)
        try await waitUntil { !output.enqueued.isEmpty }
        output.position = 1_000
        output.isExpectingSound = true
        try await waitUntil { listener.failed == [UtteranceID(utterance)] }

        #expect(!synth.isSpeaking)
        #expect(listener.finished.isEmpty)
    }

    @Test func aClockHeldForRenderingOrByPauseIsNotAStall() async throws {
        let output = Output()
        let synth = synthesizer(output: output, renderer: Renderer(), stallLimit: .milliseconds(100))
        defer { synth.stopSpeaking(at: .immediate) }
        let listener = Listener()
        synth.delegate = listener

        synth.speak(AVSpeechUtterance(string: "Rendering is slow here."))
        try await waitUntil { !output.enqueued.isEmpty }
        output.isExpectingSound = false  // Held: waiting on the next sentence
        try await Task.sleep(for: .milliseconds(400))
        output.isExpectingSound = true
        synth.pauseSpeaking(at: .word)
        try await Task.sleep(for: .milliseconds(400))

        #expect(listener.failed.isEmpty)
        #expect(synth.isSpeaking)
    }

    @Test func anOutputFailureEndsTheUtteranceWithoutFinishingIt() async throws {
        let output = Output()
        let synth = synthesizer(output: output, renderer: Renderer())
        defer { synth.stopSpeaking(at: .immediate) }
        let listener = Listener()
        synth.delegate = listener
        let utterance = AVSpeechUtterance(string: "The route changes.")

        synth.speak(utterance)
        output.onFailure?()

        #expect(listener.failed == [UtteranceID(utterance)])
        #expect(listener.finished.isEmpty)
        #expect(!synth.isSpeaking)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The expected rendering or playback event never arrived")
    }

    @Test func articleAddsOnePauseAtTheParagraphBreakWithoutPausingProcessingSplitsOrTheEnd() async throws {
        let output = Output()
        let renderer = Renderer()
        let synth = synthesizer(output: output, renderer: renderer)
        let api = FakeAPI()
        api.articleText = String(repeating: "A sentence long enough to split this paragraph into several chunks. ", count: 12)
            + "\n\nThe next paragraph."
        let chunks = ArticleScript(text: api.articleText!).chunks
        try #require(chunks.count > 2)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let article = ArticlePlayer(
            api: api, cache: OfflineCache(directory: directory), synthesizer: synth,
            defaults: defaults, progressScope: { nil }, activateAudioSession: {})
        defer { article.clear() }
        article.play(Episode(
            id: 1, title: "Paragraphs", description: nil, audioURL: nil, durationSeconds: nil,
            publishedAt: nil, link: nil, hasText: true))
        await article.waitForPendingLoad()

        for index in chunks.indices {
            try await waitUntil { output.completedChunks == index + 1 }
            output.drain()
        }

        #expect(!article.isPlaying)
        #expect(output.enqueued.filter { $0 == 0 }.count == 4_800)
        #expect(output.continuingBuffers.last == false)
    }

    @Test func preparesTheWholeNextPassageWhileCurrentAudioPlaysAndReusesItInOrder() async throws {
        let output = Output()
        let renderer = Renderer()
        let synth = synthesizer(output: output, renderer: renderer)
        defer { synth.stopSpeaking(at: .immediate) }
        let current = AVSpeechUtterance(string: "The current passage.")
        let next = AVSpeechUtterance(string: "Yes. The following sentence takes longer to generate.")

        synth.speak(current)
        synth.prepare(next.speechString)
        try await waitUntil { renderer.completed.count == 3 }
        #expect(output.enqueued == [1])
        #expect(synth.isSpeaking)

        output.drain()
        synth.speak(next)
        try await waitUntil { output.completedChunks == 2 }

        #expect(renderer.requested.count == 3)
        #expect(output.enqueued == [1, 2, 3])
        #expect(output.continuingBuffers == [true, false, false])
    }

    @Test func startsWithTheFirstPreparedSentenceWhileTheFollowingOneIsStillRendering() async throws {
        let output = Output()
        let renderer = Renderer()
        let synth = synthesizer(output: output, renderer: renderer)
        defer { synth.stopSpeaking(at: .immediate) }
        let current = AVSpeechUtterance(string: "The current passage.")
        let next = AVSpeechUtterance(string: "Yes. The following sentence takes longer to generate.")
        renderer.heldSentence = NaturalVoiceSynthesizer.sentences(in: next.speechString).last?.text

        synth.speak(current)
        synth.prepare(next.speechString)
        try await waitUntil { renderer.delay.pendingCount == 1 }
        #expect(renderer.completed.count == 2)
        output.drain()
        synth.speak(next)
        try await waitUntil { output.enqueued.count == 2 }
        #expect(renderer.delay.pendingCount == 1)
        #expect(output.completedChunks == 1)

        renderer.delay.elapse()
        try await waitUntil { output.completedChunks == 2 }
        #expect(output.enqueued == [1, 2, 3])
        #expect(renderer.requested.count == 3)
    }

    @Test func stoppingOrReplacingSpeechCancelsPreparationWithoutPlayingStaleAudio() async throws {
        let output = Output()
        let renderer = Renderer()
        let synth = synthesizer(output: output, renderer: renderer)
        defer { synth.stopSpeaking(at: .immediate) }
        let current = AVSpeechUtterance(string: "The current passage.")
        let next = "Yes. The following sentence takes longer to generate. A third sentence."
        renderer.heldSentence = NaturalVoiceSynthesizer.sentences(in: next)[1].text

        synth.speak(current)
        synth.prepare(next)
        try await waitUntil { renderer.delay.pendingCount == 1 }
        synth.stopSpeaking(at: .immediate)
        let replacement = AVSpeechUtterance(string: "A different article.")
        synth.speak(replacement)
        try await waitUntil { renderer.delay.pendingCount == 0 && output.completedChunks == 2 }

        #expect(renderer.requested.count == 4)
        #expect(renderer.completed.count == 3)
        #expect(!renderer.requested.contains("A third sentence."))
        #expect(output.enqueued == [1, 4])
    }
}
