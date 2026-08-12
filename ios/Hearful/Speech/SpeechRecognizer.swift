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
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var silenceTimer: Timer?
    private var transcript = ""

    private let timeouts = ListeningTimeouts()
    private var hasHeardSpeech = false

    func listen(onReady: @MainActor () -> Void) async throws -> String {
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

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
            buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
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
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        let interval = timeouts.interval(hasHeardSpeech: hasHeardSpeech)
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
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            log.error("speech authorisation denied: \(speechStatus.rawValue)")
            throw SpeechError.notAuthorised
        }

        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard micGranted else {
            log.error("microphone permission denied")
            throw SpeechError.notAuthorised
        }
    }

    enum SpeechError: Error {
        case notAuthorised
        case unavailable
        case recognitionFailed
    }
}
