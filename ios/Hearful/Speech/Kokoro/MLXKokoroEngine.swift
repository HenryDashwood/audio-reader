#if canImport(KokoroSwift)

    import Foundation
    import KokoroSwift
    import MLX
    import MLXUtilsLibrary

    /// Kokoro-82M running on the phone's GPU through MLX.
    ///
    /// An actor for two reasons: inference is serialised anyway — one GPU,
    /// and the reader only ever wants the next segment — and it keeps the
    /// several hundred megabytes of weights off the main actor, where loading
    /// them would freeze the interface for seconds.
    ///
    /// Loading is deferred to the first render for the same reason: building
    /// the engine happens while she is choosing a voice, and must not cost
    /// anything until she presses play.
    actor MLXKokoroEngine: KokoroRendering {
        private let modelURL: URL
        private let voicesURL: URL

        private var engine: KokoroTTS?
        private var voices: [String: MLXArray]?

        init(modelURL: URL, voicesURL: URL) {
            self.modelURL = modelURL
            self.voicesURL = voicesURL
        }

        /// Deliberately loads only the voice file. The picker asks this
        /// question while she is in Settings, and reading half a gigabyte of
        /// weights to answer it would be a long silence for nothing.
        func availableVoices() async -> [KokoroVoice] {
            guard let voices = try? loadVoices() else { return [] }
            return KokoroVoice.catalogue.filter { style(for: $0, in: voices) != nil }
        }

        func render(text: String, voice: KokoroVoice, speed: Float) async throws -> KokoroAudio {
            let voices = try loadVoices()
            guard let style = style(for: voice, in: voices) else {
                throw KokoroEngineError.voiceMissing(voice.name)
            }
            let tts = loadEngine()
            // The second element is Kokoro's per-token timings. The reader
            // only needs a fraction through the chunk, which the playhead
            // gives it, so they are dropped — but they are what a
            // word-highlighting view would be built on.
            let (samples, _) = try tts.generateAudio(
                voice: style,
                language: voice.isBritish ? .enGB : .enUS,
                text: text,
                speed: speed
            )
            return KokoroAudio(
                samples: samples, sampleRate: Double(KokoroTTS.Constants.samplingRate))
        }

        /// Voice keys carry the `.npy` suffix they had inside the archive;
        /// both spellings are accepted so a differently packed file works.
        private func style(for voice: KokoroVoice, in voices: [String: MLXArray]) -> MLXArray? {
            voices[voice.name + ".npy"] ?? voices[voice.name]
        }

        private func loadVoices() throws -> [String: MLXArray] {
            if let voices { return voices }
            guard let read = NpyzReader.read(fileFromPath: voicesURL), !read.isEmpty else {
                throw KokoroEngineError.modelMissing
            }
            voices = read
            return read
        }

        private func loadEngine() -> KokoroTTS {
            if let engine { return engine }
            let built = KokoroTTS(modelPath: modelURL)
            engine = built
            return built
        }
    }

#endif
