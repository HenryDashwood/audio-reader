import AVFoundation
import OSLog
import Speech

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "speech")

/// Wraps Apple's on-device speech recognition. Prefers local recognition —
/// free, private, and no round trip before we know what she said — but falls
/// back to Apple's servers when the on-device models are missing, which is
/// always the case in the simulator.
@MainActor
final class SpeechRecognizer: SpeechRecognizing {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var silenceTimer: Timer?
    private var transcript = ""

    private let timeouts = ListeningTimeouts()
    private var hasHeardSpeech = false
    private var arrivals = BufferArrivals()

    func listen(onReady: @MainActor () -> Void) async throws -> String {
        VoiceAttempt.current?.recogniser = "fallback"
        VoiceAttempt.current?.usedFallback = true
        try await requestPermissions()
        guard let recognizer else {
            log.error("no recogniser for this locale")
            throw SpeechError.unavailable
        }
        guard recognizer.isAvailable else {
            log.error("recogniser exists but is unavailable")
            throw SpeechError.unavailable
        }

        let preferOnDevice = recognizer.supportsOnDeviceRecognition
        do {
            return try await recognise(
                using: recognizer, onDevice: preferOnDevice, onReady: onReady)
        } catch SpeechError.recognitionFailed where preferOnDevice {
            // The device claims on-device support but has no models installed.
            log.notice("on-device recognition failed; retrying server-based")
            return try await recognise(using: recognizer, onDevice: false, onReady: onReady)
        }
    }

    private func recognise(
        using recognizer: SFSpeechRecognizer, onDevice: Bool, onReady: @MainActor () -> Void
    ) async throws -> String {
        cancel()
        transcript = ""
        hasHeardSpeech = false
        try AudioSession.configureForListening()
        log.info("listening; onDevice=\(onDevice)")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        self.request = request

        // Fresh engine, and the format checked before it is handed over: the
        // input node's cache does not survive the audio session switching to
        // playback and back, and installTap answers a stale format with an
        // Objective-C exception that Swift cannot catch. See AudioSession.
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard
            AudioSession.isUsableInputFormat(
                sampleRate: inputFormat.sampleRate, channelCount: inputFormat.channelCount)
        else {
            log.error("no usable microphone route: \(inputFormat)")
            throw SpeechError.recognitionFailed
        }
        arrivals = BufferArrivals()
        let arrivals = self.arrivals
        let requestSink = AudioBufferRequestSink(request)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            @Sendable buffer, _ in
            arrivals.record()
            requestSink.append(buffer)
        }
        engine.prepare()
        try engine.start()

        // The go-ahead waits for audio to actually be flowing, exactly as in
        // the analyser. Starting the engine is not the same as the microphone
        // being live, and a tone sounded early asks her to speak into nothing
        // — then reports it back to her as having said nothing.
        guard await arrivals.waitForFirst() else {
            log.error("no audio arrived from the microphone within \(BufferArrivals.wait)s")
            throw SpeechError.microphoneSilent
        }
        onReady()

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.restartSilenceTimer()
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.hasHeardSpeech = true
                        }
                        // Every fresh word pushes the deadline out.
                        self.restartSilenceTimer()
                        if result.isFinal { self.finish(with: .success(self.transcript)) }
                    }
                    if let error {
                        log.error("recognition error: \(error.localizedDescription)")
                        // An error after she has spoken still leaves a usable
                        // transcript; only fail outright if we have nothing.
                        if self.transcript.isEmpty {
                            self.finish(with: .failure(SpeechError.recognitionFailed))
                        } else {
                            self.finish(with: .success(self.transcript))
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            AudioSession.releaseRecording()
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Every partial result from this recogniser is a guess it may rewrite —
    /// that is what "partial" means — so while the timer is what ends the
    /// turn, the transcript is by definition unsettled. A final result
    /// finishes immediately and never reaches here.
    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        let interval = timeouts.interval(hasHeardSpeech: hasHeardSpeech, isSettled: false)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.finish(with: .success(self.transcript))
            }
        }
    }

    private func finish(with result: Result<String, Error>) {
        // Resuming a continuation twice traps, so clear it before tearing down.
        guard let pending = continuation else { return }
        continuation = nil
        cancel()
        switch result {
        case .success(let text): pending.resume(returning: text)
        case .failure(let error): pending.resume(throwing: error)
        }
    }

    private func requestPermissions() async throws {
        // @Sendable on both callbacks below is load-bearing, not decoration.
        // Speech and AVFAudio call back on their own queues; a closure written
        // inside a @MainActor type otherwise infers main-actor isolation and
        // traps off-main the instant the user answers the prompt. That is a
        // real crash on this device, not a theoretical one.
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable in
                continuation.resume(returning: $0)
            }
        }
        guard speechStatus == .authorized else {
            log.error("speech authorisation denied: \(speechStatus.rawValue)")
            throw SpeechPermissionDenied()
        }

        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { @Sendable in
                continuation.resume(returning: $0)
            }
        }
        guard micGranted else {
            log.error("microphone permission denied")
            throw SpeechPermissionDenied()
        }
    }

    /// Bridges Apple's unannotated recognition request into the realtime tap.
    ///
    /// This is the API's intended ownership pattern: the audio engine invokes
    /// its tap serially, and `cancel()` stops the engine and removes that tap
    /// before ending the request. The request therefore never receives a new
    /// buffer after teardown begins. The framework type predates Sendable, so
    /// this narrow wrapper states the lifecycle guarantee without weakening
    /// concurrency checking for the rest of the Speech framework.
    private nonisolated final class AudioBufferRequestSink: @unchecked Sendable {
        private let request: SFSpeechAudioBufferRecognitionRequest

        init(_ request: SFSpeechAudioBufferRecognitionRequest) {
            self.request = request
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            request.append(buffer)
        }
    }

    enum SpeechError: TransientRecognitionFailure {
        case unavailable
        case recognitionFailed
        /// Capture came up without error but delivered no audio at all.
        case microphoneSilent

        /// A microphone that did not wake in time is worth another go; a
        /// recogniser this locale has none of is not.
        var isTransient: Bool {
            switch self {
            case .microphoneSilent: true
            case .unavailable, .recognitionFailed: false
            }
        }
    }
}
