#if DEBUG
    import AVFoundation
    import Combine
    import os

    private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "natural-voice")

    /// Debug: renders a passage with the downloadable voice when the app is launched with
    /// `HEARFUL_NATURAL_VOICE_SELFTEST=1`, then logs how fast each sentence rendered and saves the audio to
    /// `tmp/natural-voice-selftest.wav` in the app's container, where `simctl get_app_container` finds it.
    /// It proves the engine on a simulator or phone without an article, an account or a tap.
    enum NaturalVoiceSelfTest {
        static let passage = """
            Mr. Lovelady and Mr. Calcraft testified that Oswald's rooming house stood near Clerkenwell. \
            Speed comes from the voice itself, not from stretching the audio afterwards. \
            Patreon and Vimeo both sent the Datalab team their figures on Thursday, from No. 10 Downing St. to \
            St. Paul's, about 5 km away.
            """

        static func runIfRequested() async {
            let mode = ProcessInfo.processInfo.environment["HEARFUL_NATURAL_VOICE_SELFTEST"]
            if mode == "download" || mode == "redownload" {
                await DownloadCheck.run(removingFirst: mode == "redownload")
                return
            }
            guard let mode, let selected = NaturalVoiceStore.selected() else { return }
            if mode == "synthesizer" {
                await SynthesizerCheck().run(selected)
                return
            }
            guard mode == "1" else { return }
            do {
                var start = ContinuousClock.now
                let engine = try await NaturalVoiceSynthesizer.engine(folder: selected.folder, voice: selected.voice).value
                log.notice("selftest: loaded \(selected.voice.id, privacy: .public) in \(ContinuousClock.now - start, privacy: .public)")
                var audio: [Float] = []
                // Twice: the first use of each body size includes Core ML preparing it for this device
                for pass in 1 ... 2 {
                log.notice("selftest: pass \(pass)")
                audio = []
                for piece in NaturalVoiceSynthesizer.sentences(in: passage) {
                    start = ContinuousClock.now
                    for (sentence, _) in try await NaturalVoiceSynthesizer.render(piece.text, at: piece.offset, with: engine) {
                        let elapsed = ContinuousClock.now - start
                        let seconds = Double(sentence.samples.count) / NaturalVoiceEngine.sampleRate
                        let rate = seconds / (Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds))
                        let words = sentence.words.map { (piece.text as NSString).substring(with: NSRange(location: $0.characters.lowerBound, length: $0.characters.count)) }
                        log.notice("selftest: \(String(format: "%.1f", seconds), privacy: .public)s in \(elapsed, privacy: .public), \(String(format: "%.1f", rate), privacy: .public)x real time; words \(words.joined(separator: "|"), privacy: .public)")
                        audio += sentence.samples
                        start = ContinuousClock.now
                    }
                }
                }
                let url = FileManager.default.temporaryDirectory.appending(path: "natural-voice-selftest.wav")
                let format = AVAudioFormat(standardFormatWithSampleRate: NaturalVoiceEngine.sampleRate, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count))!
                buffer.frameLength = buffer.frameCapacity
                audio.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
                log.notice("selftest: wrote \(url.path, privacy: .public)")
            } catch {
                log.error("selftest failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `HEARFUL_NATURAL_VOICE_SELFTEST=download`: downloads the asset pack as Settings' button does, logging each state
    /// (`redownload` removes it first, as Settings' Remove does),
    /// and where the voice ended up. With `ba-serve` and `scripts/voice-pack.sh point`, against a local server.
    enum DownloadCheck {
        @MainActor
        static func run(removingFirst: Bool) async {
            let download = NaturalVoiceDownload.shared
            let watcher = download.$state.sink { log.notice("selftest download: \(String(describing: $0), privacy: .public)") }
            await download.refresh()
            if removingFirst { await download.remove() }
            if case .notInstalled = download.state { await download.download() }
            log.notice("selftest download: folder \(NaturalVoiceStore.folder?.path ?? "none", privacy: .public)")
            watcher.cancel()
        }
    }

    /// `HEARFUL_NATURAL_VOICE_SELFTEST=synthesizer`: drives NaturalVoiceSynthesizer as ArticlePlayer does, through
    /// speak, pause, continue and the end, out loud, logging the words it reports and whether pausing holds them.
    @MainActor
    final class SynthesizerCheck: SpeechSynthesizingDelegate {
        private var words: [String] = []
        private var text = ""
        private var finished: CheckedContinuation<Void, Never>?

        func run(_ selected: (folder: URL, voice: NaturalVoice)) async {
            let synthesizer = NaturalVoiceSynthesizer(folder: selected.folder, voice: selected.voice)
            synthesizer.delegate = self
            text = NaturalVoiceSelfTest.passage
            synthesizer.speak(AVSpeechUtterance(string: text))
            try? await Task.sleep(for: .seconds(8))
            synthesizer.pauseSpeaking(at: .word)
            let atPause = words.count
            try? await Task.sleep(for: .seconds(3))
            log.notice("selftest synth: paused=\(synthesizer.isPaused), words while paused \(self.words.count - atPause), \(atPause) before")
            synthesizer.continueSpeaking()
            await withCheckedContinuation { finished = $0 }
            log.notice("selftest synth: finished; speaking=\(synthesizer.isSpeaking); \(self.words.count) words: \(self.words.joined(separator: "|"), privacy: .public)")
        }

        func speechProgressed(to range: NSRange, of utterance: UtteranceID) {
            words.append((text as NSString).substring(with: range))
        }

        func speechFinished(_ utterance: UtteranceID) {
            finished?.resume()
            finished = nil
        }
    }
#endif
