#if canImport(KokoroSwift)

    import Foundation
    import os

    /// Times a render on the real device, because nothing else can.
    ///
    /// MLX does not link for the simulator, so there is no way to measure this
    /// except on a phone — and running it under XCTest gets the process killed
    /// before the weights finish loading. So it runs inside the app instead,
    /// on a launch environment variable, in the manner of the fake-transcript
    /// hook used for voice flows:
    ///
    ///     xcrun devicectl device process launch --device <id> --console \
    ///       --environment-variables '{"HEARFUL_KOKORO_BENCH":"bf_emma"}' \
    ///       com.henrydashwood.hearful
    nonisolated enum KokoroBenchmark {
        static let variable = "HEARFUL_KOKORO_BENCH"

        /// One chunk-sized paragraph, the unit the reader actually renders.
        static let paragraph = """
            The trouble with the modern novel, she said, is that it has forgotten how \
            to end. It stops, which is not the same thing at all. A proper ending is \
            an argument the book has been making all along, arriving at last in a \
            form you can carry out of the room with you.
            """

        static func runIfRequested() {
            guard let voiceName = ProcessInfo.processInfo.environment[variable],
                let voice = KokoroVoice.named(voiceName) ?? KokoroVoice.catalogue.first,
                let engine = KokoroEngines.shared
            else { return }

            Task.detached(priority: .userInitiated) {
                // Well clear of the launch watchdog: loading the weights during
                // launch gets the process killed outright.
                try? await Task.sleep(for: .seconds(5))
                let text = paragraph
                func budget(_ stage: String) {
                    let bytes = os_proc_available_memory()
                    print("BENCH [\(stage)] \(bytes / 1_048_576)MB of headroom left")
                }
                print("BENCH chunk \(text.count) characters, voice \(voice.name)")
                budget("launch")
                let voices = await engine.availableVoices()
                budget("after \(voices.count) voices")
                do {
                    let cold = Date()
                    let first = try await engine.render(text: text, voice: voice, speed: 1)
                    print(String(
                        format: "BENCH cold  audio %5.2fs  render %5.2fs  RTF %5.2fx",
                        first.duration, -cold.timeIntervalSinceNow,
                        first.duration / -cold.timeIntervalSinceNow))

                    for speed in [Float(1), 2, 3] {
                        let start = Date()
                        let audio = try await engine.render(text: text, voice: voice, speed: speed)
                        let elapsed = -start.timeIntervalSinceNow
                        print(String(
                            format: "BENCH %.0fx    audio %5.2fs  render %5.2fs  RTF %5.2fx",
                            speed, audio.duration, elapsed, audio.duration / elapsed))
                    }
                    print("BENCH done")
                } catch {
                    print("BENCH failed: \(error)")
                }
            }
        }
    }

#endif
