import AVFoundation
import Foundation
import Testing

@testable import Hearful

@Suite("Natural voice prepares upcoming sentences")
@MainActor
struct NaturalVoicePreparationTests {
    private final class Output: NaturalVoiceOutput {
        var onDrained: (@MainActor () -> Void)?
        var position = 0
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
        func stop() { onDrained = nil }
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

    private func synthesizer(output: Output, renderer: Renderer) -> NaturalVoiceSynthesizer {
        NaturalVoiceSynthesizer(
            folder: URL.temporaryDirectory, voice: NaturalVoice(id: "bf_emma"),
            output: output, renderSentence: renderer.render)
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
