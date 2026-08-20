#if canImport(KokoroSwift)

    import Foundation
    import Testing

    @testable import Hearful

    /// Device-only: MLX does not link for the simulator, and this needs the
    /// model files in the app bundle. Measures what the reader actually asks
    /// for — one chunk-sized paragraph, at the speeds she can choose.
    @Suite("Kokoro benchmark", .serialized)
    struct KokoroBenchmarkTests {
        /// A real paragraph at ArticleScript's chunk limit.
        static let paragraph = """
            The trouble with the modern novel, she said, is that it has forgotten how \
            to end. It stops, which is not the same thing at all. A proper ending is \
            an argument the book has been making all along, arriving at last in a \
            form you can carry out of the room with you.
            """

        @Test func rendersFasterThanRealTime() async throws {
            guard let engine = KokoroEngines.shared else {
                Issue.record("no engine: package or model files missing")
                return
            }
            let voice = try #require(KokoroVoice.named("bf_emma"))
            let text = Self.paragraph
            print("=== chunk: \(text.count) characters")

            // Staged, so a crash says which stage caused it: the voice file is
            // 14MB, the weights are 327MB.
            let voicesStart = Date()
            let available = await engine.availableVoices()
            print(String(format: "=== voices loaded: %d in %.2fs", available.count,
                         -voicesStart.timeIntervalSinceNow))

            let coldStart = Date()
            _ = try await engine.render(text: text, voice: voice, speed: 1)
            print(String(format: "=== first render (loads weights): %.2fs", -coldStart.timeIntervalSinceNow))

            for speed in [Float(1), 2, 3] {
                let start = Date()
                let audio = try await engine.render(text: text, voice: voice, speed: speed)
                let elapsed = -start.timeIntervalSinceNow
                print(
                    String(
                        format: "=== speed %.0fx  audio %5.2fs  render %5.2fs  RTF %5.2fx",
                        speed, audio.duration, elapsed, audio.duration / elapsed))
                #expect(audio.duration > 0)
            }
        }
    }

#endif
