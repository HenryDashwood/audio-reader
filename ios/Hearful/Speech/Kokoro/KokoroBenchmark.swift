#if canImport(KokoroSwift) && !targetEnvironment(simulator)

    import Foundation
    import os

    /// Times and captures a render on the real device, because MLX inference
    /// requires a Metal GPU that the simulator does not provide, and loading
    /// the weights under XCTest gets the process killed. So it runs inside the
    /// app on a launch environment variable, in the manner of the
    /// fake-transcript hook used for voice flows:
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
                try? await Task.sleep(for: .seconds(3))
                guard let documents = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask).first
                else { return }

                // Real article text if it has been pushed to the container,
                // since synthetic prose has never reproduced this.
                let source = documents.appendingPathComponent("article.txt")
                let text = (try? String(contentsOf: source, encoding: .utf8)) ?? paragraph
                print("BENCH text \(text.count) characters")

                // Chunked exactly as the reader chunks it, then segmented
                // exactly as the synthesiser segments it.
                let speed = Float(
                    ProcessInfo.processInfo.environment["HEARFUL_KOKORO_SPEED"] ?? "1") ?? 1
                print("BENCH speed \(speed)")
                let script = ArticleScript(text: text)
                var index = 0
                outer: for chunk in script.chunks {
                    for segment in KokoroSynthesizer.segments(of: chunk.text) {
                        guard index < 14 else { break outer }
                        guard let audio = try? await engine.render(
                            text: segment, voice: voice, speed: speed) else { continue }
                        try? wav(audio).write(
                            to: documents.appendingPathComponent("a-\(index).wav"))
                        print(String(format: "BENCH seg %2d  %3d chars  %5.2fs  |%@|",
                                     index, segment.count, audio.duration,
                                     segment as NSString))
                        index += 1
                    }
                }
                print("BENCH done")
            }
        }

        /// Renders and plays exactly as the reader does, capturing what the
        /// audio engine puts out.
        @MainActor
        private static func playThrough(
            engine: KokoroRendering, voice: KokoroVoice, text: String, to url: URL
        ) async {
            print("BENCH play: start")
            let output = KokoroAudioEngineOutput()
            let segments = KokoroSynthesizer.segments(of: text)
            print("BENCH play: \(segments.count) segments")
            var rendered: [KokoroAudio] = []
            for segment in segments {
                guard let audio = try? await engine.render(text: segment, voice: voice, speed: 1)
                else { continue }
                rendered.append(audio)
            }
            print("BENCH play: rendered \(rendered.count)")
            var capture: KokoroAudioEngineOutput.Capture?
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                output.onDrained = { continuation.resume() }
                // The first buffer starts the engine, so the tap can only go on
                // once one has been handed over.
                print("BENCH play: enqueue first")
                if let first = rendered.first { output.enqueue(first) }
                print("BENCH play: installing tap")
                capture = output.startCapture()
                print("BENCH play: tap installed")
                for audio in rendered.dropFirst() { output.enqueue(audio) }
                output.finishEnqueueing()
            }
            output.stopCapture()
            output.shutDown()
            if let heard = capture?.take() {
                try? wav(heard).write(to: url)
                print(String(format: "BENCH played back %.2fs at %.0fHz -> %@",
                             heard.duration, heard.sampleRate, url.lastPathComponent as NSString))
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
