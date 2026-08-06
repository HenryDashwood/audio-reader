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

    /// How long a pause counts as "she has finished speaking".
    private let silenceThreshold: TimeInterval = 1.5

    init(locale: Locale = Locale(identifier: "en-GB")) {
        self.locale = locale
    }

    func listen() async throws -> String {
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

        try startCapture(convertingTo: format)
        log.info("analyzer listening")

        defer { cancel() }
        return try await collectTranscript(from: transcriber)
    }

    /// Reads results until she stops speaking. Each new phrase pushes the
    /// silence deadline out, so pausing mid-sentence does not cut her off.
    private func collectTranscript(from transcriber: SpeechTranscriber) async throws -> String {
        var finalised = ""
        var volatile = ""

        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalised += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    self.restartSilenceTimer()
                }
                return finalised + volatile
            }
            group.addTask { @MainActor in
                await self.waitForSilence()
                return nil  // silence wins: return whatever we have so far
            }

            let first = try await group.next() ?? nil
            group.cancelAll()
            return first ?? (finalised + volatile)
        }
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
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) {
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
    private func startCapture(convertingTo format: AVAudioFormat) throws {
        try AudioSession.configureForListening()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: format)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = Self.convert(buffer, using: converter, to: format) else { return }
            self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        try engine.start()
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
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
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
            throw SpeechError.notAuthorised
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
        case notAuthorised
        case noCompatibleAudioFormat
    }
}
