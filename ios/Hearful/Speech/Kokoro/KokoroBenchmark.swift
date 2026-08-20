#if canImport(KokoroSwift)

    import Foundation
    import os

    /// Times and captures a render on the real device, because nothing else
    /// can: MLX does not link for the simulator, and loading the weights under
    /// XCTest gets the process killed. So it runs inside the app on a launch
    /// environment variable, in the manner of the fake-transcript hook used for
    /// voice flows:
    ///
    ///     xcrun devicectl device process launch --device <id> --console \
    ///       --environment-variables '{"HEARFUL_KOKORO_BENCH":"1"}' \
    ///       com.henrydashwood.hearful
    ///
    /// The WAVs it writes come back with:
    ///
    ///     xcrun devicectl device copy from --device <id> --user mobile \
    ///       --domain-type appDataContainer \
    ///       --domain-identifier com.henrydashwood.hearful \
    ///       --source Documents/joined-para-a.wav --destination .
    nonisolated enum KokoroBenchmark {
        static let variable = "HEARFUL_KOKORO_BENCH"

        static let paragraph = """
            The trouble with the modern novel, she said, is that it has forgotten how \
            to end. It stops, which is not the same thing at all. A proper ending is \
            an argument the book has been making all along, arriving at last in a \
            form you can carry out of the room with you.
            """

        /// A second paragraph, so a length effect can be told apart from one
        /// unlucky word in the first.
        static let other = """
            Sound recording was invented twice over, and the second time nobody \
            noticed. What changed was not the microphone but the expectation that a \
            voice could be kept at all, and played back to a room that had never \
            contained it.
            """

        static func runIfRequested() {
            guard ProcessInfo.processInfo.environment[variable] != nil,
                let engine = KokoroEngines.shared,
                let voice = KokoroVoice.named("bf_emma")
            else { return }

            Task.detached(priority: .userInitiated) {
                // Clear of the launch watchdog.
                try? await Task.sleep(for: .seconds(3))
                guard let documents = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask).first
                else { return }
                print("BENCH \(os_proc_available_memory() / 1_048_576)MB of headroom")

                for (name, text) in [("para-a", paragraph), ("para-b", other)] {
                    // Exactly what the reader does: the same segmentation, in
                    // the same order, joined as the player would hear them.
                    let segments = KokoroSynthesizer.segments(of: text)
                    var joined: [Float] = []
                    var rate = 24000.0
                    let start = Date()
                    for segment in segments {
                        guard let audio = try? await engine.render(
                            text: segment, voice: voice, speed: 1)
                        else { continue }
                        joined.append(contentsOf: audio.samples)
                        rate = audio.sampleRate
                    }
                    let whole = KokoroAudio(samples: joined, sampleRate: rate)
                    try? wav(whole).write(
                        to: documents.appendingPathComponent("joined-\(name).wav"))
                    print(String(
                        format: "BENCH %@ %d chars, %d segments (longest %d)  audio %6.2fs  render %5.2fs",
                        name as NSString, text.count, segments.count,
                        segments.map(\.count).max() ?? 0, whole.duration,
                        -start.timeIntervalSinceNow))
                }
                print("BENCH done")
            }
        }

        private static func wav(_ audio: KokoroAudio) -> Data {
            var data = Data()
            let rate = UInt32(audio.sampleRate)
            let byteCount = UInt32(audio.samples.count * 2)
            func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
            data.append("RIFF".data(using: .ascii)!)
            append(UInt32(36 + byteCount))
            data.append("WAVEfmt ".data(using: .ascii)!)
            append(UInt32(16))
            append(UInt16(1))
            append(UInt16(1))
            append(rate)
            append(rate * 2)
            append(UInt16(2))
            append(UInt16(16))
            data.append("data".data(using: .ascii)!)
            append(byteCount)
            for sample in audio.samples { append(Int16(max(-1, min(1, sample)) * 32767)) }
            return data
        }
    }

#endif
