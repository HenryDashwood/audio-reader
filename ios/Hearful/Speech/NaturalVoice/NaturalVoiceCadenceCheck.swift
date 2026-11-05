#if HEARFUL_VOICE_TIMING
    import AVFoundation
    import Combine
    import Foundation

    /// The audio tap is the only writer. Its samples and timestamp are protected
    /// by this lock; the main actor takes a snapshot only after removing the tap.
    nonisolated final class NaturalVoiceTimingCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var sampleRate = 0.0
        private var firstBufferAt: ContinuousClock.Instant?

        init() { samples.reserveCapacity(3_840_000) }

        func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            lock.withLock {
                if firstBufferAt == nil { firstBufferAt = .now }
                sampleRate = buffer.format.sampleRate
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
            }
        }

        func snapshot() -> (samples: [Float], sampleRate: Double, firstBufferAt: ContinuousClock.Instant?) {
            lock.withLock { (samples, sampleRate, firstBufferAt) }
        }
    }

    /// Local Release builds can opt into a measured playback check. Ordinary
    /// builds do not compile this harness or install an audio tap.
    @MainActor
    final class NaturalVoiceCadenceCheck {
        private let output = NaturalVoiceAudioOutput()
        private var synth: NaturalVoiceSynthesizer!

        static func runIfRequested() async -> Bool {
            guard ProcessInfo.processInfo.environment["HEARFUL_VOICE_TIMING"] == "1" else { return false }
            do { try await NaturalVoiceCadenceCheck().run() }
            catch { print("VOICE_TIMING_ERROR \(error)") }
            return true
        }

        private func run() async throws {
            guard let selected = NaturalVoiceStore.selected() else {
                print("VOICE_TIMING_ERROR no selected downloaded voice")
                return
            }
            print("VOICE_TIMING_START voice=\(selected.voice.id)")
            synth = NaturalVoiceSynthesizer(folder: selected.folder, voice: selected.voice, output: output)
            let passage = """
                Yes. The Congress of Vienna redrew the map of Europe after years of war, and the diplomats argued about the borders until the spring.

                Then it rained. Mr. Lovelady and Mr. Calcraft testified that Oswald's rooming house stood near Clerkenwell.

                The afternoon was quiet. Speed comes from the voice itself, not from stretching the audio afterwards.
                """
            let directory = URL.temporaryDirectory.appending(path: "voice-timing-\(UUID().uuidString)")
            let cache = OfflineCache(directory: directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let suite = "voice-timing-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let episode = Episode(
                id: 999_999_999, title: "Voice timing check", description: nil,
                audioURL: nil, durationSeconds: nil, publishedAt: nil, link: nil,
                imageURL: nil, positionSeconds: nil, completed: nil, hasText: true)
            cache.saveArticle(EpisodeText(episodeID: episode.id, title: episode.title, text: passage, html: nil))
            let article = ArticlePlayer(cache: cache, synthesizer: synth, defaults: defaults, progressScope: { nil })
            article.feedback = SilentFeedback()
            defer { article.clear() }
            for pass in 1...2 {
                article.restore(episode)
                await article.waitForPendingLoad()
                guard article.isReadyToPlay else {
                    print("VOICE_TIMING_ERROR cached article did not load")
                    break
                }
                let capture = NaturalVoiceTimingCapture()
                output.beginTimingCapture(capture)
                let requestedAt = ContinuousClock.now
                var finished: AnyCancellable?
                await withCheckedContinuation { continuation in
                    finished = article.finished.prefix(1).sink { continuation.resume() }
                    article.resume()
                }
                finished?.cancel()
                try await Task.sleep(for: .milliseconds(250))
                output.endTimingCapture()
                let recorded = capture.snapshot()
                guard recorded.sampleRate > 0, !recorded.samples.isEmpty else {
                    print("VOICE_TIMING_ERROR no mixer audio captured")
                    continue
                }
                let peak = recorded.samples.lazy.map { abs($0) }.max() ?? 0
                let threshold = max(0.0001, peak * 0.03)
                let window = max(1, Int(recorded.sampleRate * 0.01))
                var silentFrom: Int?
                var heardSpeech = false
                var firstSound: Int?
                var gaps: [Double] = []
                for start in stride(from: 0, to: recorded.samples.count, by: window) {
                    let end = min(recorded.samples.count, start + window)
                    let audible = recorded.samples[start..<end].contains { abs($0) >= threshold }
                    if audible {
                        if firstSound == nil { firstSound = start }
                        if heardSpeech, let from = silentFrom {
                            let gap = Double(start - from) / recorded.sampleRate
                            if gap >= 0.15 { gaps.append(gap) }
                        }
                        heardSpeech = true
                        silentFrom = nil
                    } else if silentFrom == nil {
                        silentFrom = start
                    }
                }
                let lead = recorded.firstBufferAt.map { requestedAt.duration(to: $0) }
                let leadSeconds = lead.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 0
                let startup = leadSeconds + Double(firstSound ?? 0) / recorded.sampleRate
                let format = AVAudioFormat(standardFormatWithSampleRate: recorded.sampleRate, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(recorded.samples.count))!
                buffer.frameLength = buffer.frameCapacity
                recorded.samples.withUnsafeBufferPointer {
                    buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count)
                }
                let url = URL.temporaryDirectory.appending(path: "natural-voice-cadence-\(pass).wav")
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
                let report: [String: Any] = [
                    "pass": pass, "voice": selected.voice.id, "startup_seconds": startup,
                    "gaps_seconds": gaps, "sample_rate": recorded.sampleRate,
                    "duration_seconds": Double(recorded.samples.count) / recorded.sampleRate,
                    "audio_path": url.path,
                    "path": "ArticlePlayer",
                ]
                let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                try json.write(to: URL.temporaryDirectory.appending(path: "natural-voice-cadence-\(pass).json"))
                print("VOICE_TIMING_RESULT \(String(decoding: json, as: UTF8.self))")
                article.clear()
            }
            synth.stopSpeaking(at: .immediate)
            print("VOICE_TIMING_FINISHED")
        }
    }
#endif
