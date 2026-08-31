import AVFoundation
import OSLog
import Speech

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "speech")

/// Apple's iOS 26 system-dictation recogniser, hosted by SpeechAnalyzer.
/// DictationTranscriber uses the same speech-to-text models as keyboard
/// Dictation while keeping audio on-device.
@MainActor
final class AnalyzerSpeechRecognizer: SpeechRecognizing {
    /// Keep live guesses so the UI can stop promptly, but avoid frequent
    /// finalisation: Apple documents that option as more responsive at the
    /// cost of accuracy. Far-field tuning matches the phone-at-a-distance
    /// conditions in which voice control is normally used.
    static let accuracyBiasedPreset: DictationTranscriber.Preset = {
        let progressive = DictationTranscriber.Preset.progressiveShortDictation
        return DictationTranscriber.Preset(
            contentHints: progressive.contentHints.union([.farField]),
            transcriptionOptions: progressive.transcriptionOptions,
            reportingOptions: progressive.reportingOptions.subtracting([.frequentFinalization]),
            attributeOptions: progressive.attributeOptions)
    }()

    private let locale: Locale
    private var engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var silenceTimer: Timer?

    private let timeouts = ListeningTimeouts()
    /// Counts buffers arriving from the microphone tap. Zero is the one
    /// thing that cannot mean "she said nothing": the tap delivers audio
    /// continuously once capture is live, and silence is still audio. Zero
    /// means the capture path never came up at all.
    private var arrivals = BufferArrivals()
    /// Set once any words arrive, which switches the wait from "waiting for
    /// her to begin" to "she has finished".
    private var hasHeardSpeech = false
    private var onPartial: (@MainActor (String) -> Void)?

    init(locale: Locale = Locale(identifier: "en-GB")) {
        self.locale = locale
    }

    func listen(onReady: @MainActor () -> Void) async throws -> String {
        try await listen(onReady: onReady, onPartial: { _ in })
    }

    func listen(
        onReady: @MainActor () -> Void,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        hasHeardSpeech = false
        self.onPartial = onPartial
        defer { self.onPartial = nil }
        VoiceAttempt.current?.recogniser = "dictation-transcriber"
        try await requestMicrophonePermission()

        let transcriber = DictationTranscriber(locale: locale, preset: Self.accuracyBiasedPreset)
        try await ensureModelInstalled(for: transcriber)

        guard
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber])
        else {
            throw SpeechError.noCompatibleAudioFormat
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)

        arrivals = BufferArrivals()
        try startCapture(convertingTo: format, into: continuation)

        // The tone means "speak now", and she believes it — so it must not
        // sound until the microphone is genuinely delivering audio. Starting
        // the engine is not the same thing: `engine.start()` returns before
        // the route is necessarily live, and a tone sounded then invites her
        // to say a whole sentence into nothing. That is what "I did not hear
        // anything" was, on the first request after launch, every time.
        //
        // Failing here rather than after she has spoken is the point. Once
        // she has said her piece the audio is gone and falling back to
        // another recogniser buys nothing; before the tone, the backup gets
        // to hear the real sentence.
        guard await arrivals.waitForFirst() else {
            log.error("no audio arrived from the microphone within \(BufferArrivals.wait)s")
            throw SpeechError.microphoneSilent
        }
        log.info("analyzer listening")
        onReady()

        defer {
            cancel()
        }
        return try await collectTranscript(from: transcriber)
    }

    /// Live transcription so far. On the actor rather than captured locals:
    /// both racing tasks below must see one serialized copy, and Swift 6's
    /// race checker rightly rejects sharing mutable captures between tasks.
    private var finalised = ""
    private var volatile = ""

    /// Reads results until she stops speaking, then explicitly asks Apple's
    /// analyser to finish the audio it already has. The finalisation step is
    /// load-bearing: silence commonly arrives while DictationTranscriber is
    /// still holding a plausible-but-wrong guess, and returning that volatile
    /// text is how names such as "Dattani" became "attorney".
    private func collectTranscript(from transcriber: DictationTranscriber) async throws -> String {
        finalised = ""
        volatile = ""

        let reader = Task { @MainActor in
            try await self.readResults(from: transcriber)
        }

        await waitForSilence()
        let provisional = finalised + volatile
        VoiceAttempt.current?.settledBeforeFinalization = isSettled

        // End the input sequence before asking the analyser to finish through
        // its end. This preserves all captured audio while preventing another
        // microphone buffer from moving the finishing line underneath it.
        stopCapture()
        guard let analyzer else {
            // The sheet was closed while the silence timer was pending.
            reader.cancel()
            return provisional
        }

        let startedFinalizing = ContinuousClock.now
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            self.analyzer = nil
            let transcript = try await reader.value
            let elapsed = ContinuousClock.now - startedFinalizing
            VoiceAttempt.current?.finalizationSeconds =
                Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            VoiceAttempt.current?.finalizedTranscriptChanged = transcript != provisional
            VoiceAttempt.current?.settledAtEnd = isSettled

            // Publish once more even when the final words arrived in the same
            // scheduler turn. The line on screen must be the exact string
            // returned to VoiceController and sent to the backend.
            onPartial?(transcript)
            return transcript
        } catch {
            reader.cancel()
            throw error
        }
    }

    private func readResults(from transcriber: DictationTranscriber) async throws -> String {
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasHeardSpeech = true
            }
            if result.isFinal {
                finalised += text
                volatile = ""
            } else {
                volatile = text
            }
            onPartial?(finalised + volatile)
            restartSilenceTimer()
        }
        return finalised + volatile
    }

    private func waitForSilence() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            silenceContinuation = continuation
            restartSilenceTimer()
        }
    }

    private var silenceContinuation: CheckedContinuation<Void, Never>?

    /// The transcript is settled when the transcriber has finalised everything
    /// it has heard. A non-empty `volatile` means it is still holding a guess
    /// it may yet rewrite — which is not a moment to stop listening.
    private var isSettled: Bool { volatile.isEmpty }

    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        let interval = timeouts.interval(hasHeardSpeech: hasHeardSpeech, isSettled: isSettled)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let pending = self.silenceContinuation else { return }
                self.silenceContinuation = nil
                pending.resume()
            }
        }
    }

    /// The microphone's native format rarely matches what the analyser wants,
    /// so every buffer is converted on the way through.
    private func startCapture(
        convertingTo format: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        try AudioSession.configureForListening()

        // A fresh engine every time. AVAudioEngine's input node caches the
        // format of the route it was built against, and that cache does not
        // survive the audio session moving to playback and back — which is
        // exactly what happens between a failed attempt and her tapping to
        // try again. Reusing the engine there installs a tap with a stale
        // format, and AVFoundation answers that by killing the process.
        engine = AVAudioEngine()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard
            AudioSession.isUsableInputFormat(
                sampleRate: inputFormat.sampleRate, channelCount: inputFormat.channelCount)
        else {
            log.error("no usable microphone route: \(inputFormat)")
            throw SpeechError.microphoneUnavailable
        }
        let tap = TapConversion(
            converter: AVAudioConverter(from: inputFormat, to: format), format: format)

        input.removeTap(onBus: 0)
        // @Sendable, and self deliberately NOT captured: the engine invokes
        // this on its realtime tap queue, and a closure that is (or infers)
        // main-actor isolation traps the moment the first buffer arrives.
        // The stream continuation is Sendable and safe to feed from there.
        let arrivals = self.arrivals
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            @Sendable buffer, _ in
            arrivals.record()
            guard let converted = Self.convert(buffer, using: tap.converter, to: tap.format)
            else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        try engine.start()
    }

    /// The converter and target format, boxed for the tap queue. @unchecked
    /// Sendable is honest: both are created here and then touched only from
    /// the tap's own serial queue — the compiler just cannot see that.
    private struct TapConversion: @unchecked Sendable {
        let converter: AVAudioConverter?
        let format: AVAudioFormat
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter?, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        // The input block is typed @Sendable, so a captured `var` and the
        // non-Sendable buffer both look like races to the compiler. They are
        // not: convert(to:error:withInputFrom:) calls this block synchronously
        // on this thread and returns only once it is done with it, so nothing
        // else can observe either value. Boxing says that in the one way the
        // compiler accepts — same bargain as TapConversion above.
        let source = ConversionSource(buffer: buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if source.supplied {
                status.pointee = .noDataNow
                return nil
            }
            source.supplied = true
            status.pointee = .haveData
            return source.buffer
        }
        return error == nil ? output : nil
    }

    /// One buffer, offered to the converter exactly once.
    ///
    /// A class rather than locals so the whole thing crosses into the
    /// @Sendable input block as a single reference. @unchecked is load-bearing
    /// and deliberate: see the call site for why there is no concurrent access
    /// to be unsafe about.
    ///
    /// `nonisolated` because nested types inherit the enclosing type's
    /// isolation, and this one is used from the tap's realtime queue, which is
    /// the one place that must never touch the main actor.
    private nonisolated final class ConversionSource: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    /// The language model is a download, not part of the OS image.
    private func ensureModelInstalled(for transcriber: DictationTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber])
        {
            log.notice("downloading speech model for \(self.locale.identifier)")
            try await request.downloadAndInstall()
        }
    }

    private func requestMicrophonePermission() async throws {
        let granted = await withCheckedContinuation { continuation in
            // @Sendable is load-bearing: AVAudioApplication calls this back on
            // its own queue, and a closure written inside a @MainActor type
            // otherwise infers main-actor isolation and traps off-main.
            AVAudioApplication.requestRecordPermission { @Sendable in
                continuation.resume(returning: $0)
            }
        }
        guard granted else {
            log.error("microphone permission denied")
            throw SpeechPermissionDenied()
        }
    }

    /// Stop feeding the analyser but leave its fate to the caller. The normal
    /// path follows this with graceful finalisation; cancellation follows it
    /// with an immediate finish.
    private func stopCapture() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            AudioSession.releaseRecording()
        }
        inputContinuation?.finish()
        inputContinuation = nil
    }

    func cancel() {
        silenceContinuation?.resume()
        silenceContinuation = nil
        stopCapture()
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }

    enum SpeechError: TransientRecognitionFailure {
        case noCompatibleAudioFormat
        /// No usable input route. Thrown rather than allowed to become an
        /// uncatchable Objective-C exception inside installTap, so the
        /// fallback recogniser gets its turn and she hears a sentence
        /// instead of the app vanishing.
        case microphoneUnavailable
        /// Capture came up without error but delivered no audio at all.
        /// Seen on the first request after launch, and gone by the second
        /// — so the recogniser is fine and only this attempt was not.
        case microphoneSilent

        /// Only the audio-route failures are worth another go. A device with
        /// no compatible format will not grow one, and retrying it costs her
        /// a second or two of waiting before every single request.
        var isTransient: Bool {
            switch self {
            case .microphoneSilent, .microphoneUnavailable: true
            case .noCompatibleAudioFormat: false
            }
        }
    }
}
