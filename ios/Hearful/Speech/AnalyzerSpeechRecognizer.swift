import AVFoundation
import OSLog
import Speech

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "speech")

/// Speech recognition on iOS 26's SpeechAnalyzer. Unlike the older
/// SFSpeechRecognizer this is built for long-form, fully on-device
/// transcription: no server round trip, no time limit, and it works offline
/// once the language model has been downloaded.
@MainActor
final class AnalyzerSpeechRecognizer: SpeechRecognizing {
    private let locale: Locale
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var silenceTimer: Timer?

    private let timeouts = ListeningTimeouts()
    /// Set once any words arrive, which switches the wait from "waiting for
    /// her to begin" to "she has finished".
    private var hasHeardSpeech = false

    init(locale: Locale = Locale(identifier: "en-GB")) {
        self.locale = locale
    }

    func listen(onReady: @MainActor () -> Void) async throws -> String {
        hasHeardSpeech = false
        try await requestMicrophonePermission()

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
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

        try startCapture(convertingTo: format, into: continuation)
        log.info("analyzer listening")
        onReady()

        defer { cancel() }
        return try await collectTranscript(from: transcriber)
    }

    /// Live transcription so far. On the actor rather than captured locals:
    /// both racing tasks below must see one serialized copy, and Swift 6's
    /// race checker rightly rejects sharing mutable captures between tasks.
    private var finalised = ""
    private var volatile = ""

    /// Reads results until she stops speaking. Each new phrase pushes the
    /// silence deadline out, so pausing mid-sentence does not cut her off.
    private func collectTranscript(from transcriber: SpeechTranscriber) async throws -> String {
        finalised = ""
        volatile = ""

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.readResults(from: transcriber) }
            group.addTask { await self.silenceFallback() }

            guard let first = try await group.next() else { return "" }
            group.cancelAll()
            return first
        }
    }

    private func readResults(from transcriber: SpeechTranscriber) async throws -> String {
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
            restartSilenceTimer()
        }
        return finalised + volatile
    }

    /// Silence wins the race: hand back whatever she has said so far.
    private func silenceFallback() async -> String {
        await waitForSilence()
        return finalised + volatile
    }

    private func waitForSilence() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            silenceContinuation = continuation
            restartSilenceTimer()
        }
    }

    private var silenceContinuation: CheckedContinuation<Void, Never>?

    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        let interval = timeouts.interval(hasHeardSpeech: hasHeardSpeech)
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

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let tap = TapConversion(
            converter: AVAudioConverter(from: inputFormat, to: format), format: format)

        input.removeTap(onBus: 0)
        // @Sendable, and self deliberately NOT captured: the engine invokes
        // this on its realtime tap queue, and a closure that is (or infers)
        // main-actor isolation traps the moment the first buffer arrives.
        // The stream continuation is Sendable and safe to feed from there.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            @Sendable buffer, _ in
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
    private func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber])
        {
            log.notice("downloading speech model for \(self.locale.identifier)")
            try await request.downloadAndInstall()
        }
    }

    private func requestMicrophonePermission() async throws {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard granted else {
            log.error("microphone permission denied")
            throw SpeechPermissionDenied()
        }
    }

    func cancel() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        silenceContinuation?.resume()
        silenceContinuation = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }

    enum SpeechError: Error {
        case noCompatibleAudioFormat
    }
}
