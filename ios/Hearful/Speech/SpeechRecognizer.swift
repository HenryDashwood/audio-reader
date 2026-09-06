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
    private var onPartial: (@MainActor (String) -> Void)?

    private var activeID: UUID?
    private var tapInstalled = false
    private var finalizing = false
    private var finalizationTimer: Task<Void, Never>?
    private var captureDeadline: Task<Void, Never>?
    private var vocabulary: [String] = []
    private var onCaptureEnded: (@MainActor () -> Void)?

    func configure(vocabulary: [String], onCaptureEnded: @escaping @MainActor () -> Void) {
        self.vocabulary = vocabulary
        self.onCaptureEnded = onCaptureEnded
    }

    private func checkActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
    }

    private let timeouts = ListeningTimeouts()
    private var hasHeardSpeech = false
    private var arrivals = BufferArrivals()

    func listen(onReady: @MainActor () -> Void) async throws -> String {
        try await listen(onReady: onReady, onPartial: { _ in })
    }

    func listen(
        onReady: @MainActor () -> Void,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let id = UUID()
        activeID = id
        self.onPartial = onPartial
        defer { if activeID == id { cancel() } }
        VoiceAttempt.current?.recogniser = "fallback"
        VoiceAttempt.current?.usedFallback = true
        try await requestPermissions()
        try checkActive(id)
        guard let recognizer else {
            log.error("no recogniser for this locale")
            throw SpeechError.unavailable
        }
        guard recognizer.isAvailable else {
            log.error("recogniser exists but is unavailable")
            throw SpeechError.unavailable
        }

        var captured = false
        let ready: @MainActor () -> Void = { captured = true; onReady() }
        let preferOnDevice = recognizer.supportsOnDeviceRecognition
        do {
            return try await recognise(
                using: recognizer, onDevice: preferOnDevice, id: id, onReady: ready)
        } catch SpeechError.recognitionFailed where preferOnDevice && !captured {
            try checkActive(id)
            // The device claims on-device support but has no models installed.
            log.notice("on-device recognition failed; retrying server-based")
            return try await recognise(using: recognizer, onDevice: false, id: id, onReady: ready)
        }
    }

    private func recognise(
        using recognizer: SFSpeechRecognizer, onDevice: Bool, id: UUID, onReady: @MainActor () -> Void
    ) async throws -> String {
        tearDown()
        try checkActive(id)
        finalizing = false
        transcript = ""
        hasHeardSpeech = false
        try AudioSession.configureForListening()
        log.info("listening; onDevice=\(onDevice)")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = vocabulary
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
        tapInstalled = true
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
        try checkActive(id)
        onReady()

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.restartSilenceTimer()
            self.captureDeadline = Task {
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                guard self.activeID == id else { return }
                self.finishListening()
            }
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.activeID == id else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        self.onPartial?(self.transcript)
                        if !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.hasHeardSpeech = true
                        }
                        // Every fresh word pushes the deadline out.
                        self.restartSilenceTimer()
                        if result.isFinal { self.finish(with: .success(self.transcript)) }
                    }
                    if let error {
                        log.error("recognition error: \(error.localizedDescription)")
                        // An error does not establish that a partial guess is
                        // final, so it must not be executed as a command.
                        self.finish(with: .failure(CapturedSpeechFailure()))
                    }
                }
            }
        }
    }

    func cancel() {
        activeID = nil
        let pending = continuation
        continuation = nil
        tearDown()
        onPartial = nil
        pending?.resume(throwing: CancellationError())
    }

    private func stopCapture() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        AudioSession.releaseRecording()
        request?.endAudio()
    }

    func finishListening() {
        guard continuation != nil, !finalizing else { return }
        finalizing = true
        silenceTimer?.invalidate()
        captureDeadline?.cancel()
        stopCapture()
        onCaptureEnded?()
        let id = activeID
        finalizationTimer = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard self.activeID == id else { return }
            // A partial guess is not safe to execute as a settled request.
            self.finish(with: self.transcript.isEmpty ? .success("") : .failure(CapturedSpeechFailure()))
        }
    }

    private func tearDown() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        captureDeadline?.cancel()
        finalizationTimer?.cancel()
        captureDeadline = nil
        finalizationTimer = nil
        stopCapture()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Every partial result from this recogniser is a guess it may rewrite —
    /// that is what "partial" means — so while the timer is what ends the
    /// turn, the transcript is by definition unsettled. A final result
    /// finishes immediately and never reaches here.
    private func restartSilenceTimer() {
        guard !finalizing else { return }
        silenceTimer?.invalidate()
        let interval = timeouts.interval(hasHeardSpeech: hasHeardSpeech, isSettled: false)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.finishListening()
            }
        }
    }

    private func finish(with result: Result<String, Error>) {
        // Resuming a continuation twice traps, so clear it before tearing down.
        guard let pending = continuation else { return }
        continuation = nil
        tearDown()
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
