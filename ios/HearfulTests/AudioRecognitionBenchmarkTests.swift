import AVFoundation
import Foundation
import Speech
import Testing

@testable import Hearful

/// Opt-in replay of a local corpus. Ordinary CI never downloads models,
/// records a microphone, or sends the recordings anywhere.
@Suite("Recorded speech benchmark", .serialized)
@MainActor
struct AudioRecognitionBenchmarkTests {
    struct Recording: Decodable {
        let id: String
        let path: String
        let expected: String
        var vocabulary: [String] = []
    }

    struct Measurement: Encodable {
        let id: String
        let recognizer: String
        let expected: String
        let transcript: String
        let wordErrorRate: Double
        let seconds: Double
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEARFUL_AUDIO_EVAL_MANIFEST"] != nil))
    func replayRecordings() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manifest = try #require(environment["HEARFUL_AUDIO_EVAL_MANIFEST"])
        let recordings = try JSONDecoder().decode([Recording].self, from: Data(contentsOf: URL(filePath: manifest)))
        var measurements: [Measurement] = []
        for recording in recordings {
            for modern in [false, true] {
                let start = ContinuousClock.now
                let transcript = try await transcribe(recording, modern: modern)
                let elapsed = ContinuousClock.now - start
                measurements.append(Measurement(id: recording.id, recognizer: modern ? "speech" : "dictation",
                    expected: recording.expected, transcript: transcript,
                    wordErrorRate: Self.wordErrorRate(expected: recording.expected, actual: transcript),
                    seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
            }
        }
        let destination = environment["HEARFUL_AUDIO_EVAL_OUTPUT"] ?? NSTemporaryDirectory() + "magpie-audio-eval.json"
        try JSONEncoder().encode(measurements).write(to: URL(filePath: destination), options: .atomic)
        print("Audio benchmark: \(destination)")
    }

    private func transcribe(_ recording: Recording, modern: Bool) async throws -> String {
        let locale = Locale(identifier: "en-GB")
        let dictation = DictationTranscriber(locale: locale, preset: AnalyzerSpeechRecognizer.accuracyBiasedPreset)
        let speech = SpeechTranscriber(locale: locale, preset: .transcription)
        let module: any SpeechModule = modern ? speech : dictation
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let context = AnalysisContext()
        context.contextualStrings[.general] = recording.vocabulary
        try await analyzer.setContext(context)
        let reader = Task { @MainActor in
            var text = ""
            if modern {
                for try await result in speech.results where result.isFinal { text += String(result.text.characters) }
            } else {
                for try await result in dictation.results where result.isFinal { text += String(result.text.characters) }
            }
            return text
        }
        do {
            let result = try await withVoiceDeadline(seconds: 60) {
                let audio = try AVAudioFile(forReading: URL(filePath: recording.path))
                try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
                return try await reader.value
            }
            reader.cancel()
            await analyzer.cancelAndFinishNow()
            return result
        } catch {
            reader.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    static func wordErrorRate(expected: String, actual: String) -> Double {
        func words(_ text: String) -> [String] {
            String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").map(String.init)
        }
        let reference = words(expected), hypothesis = words(actual)
        var previous = Array(0...hypothesis.count)
        for (i, word) in reference.enumerated() {
            var next = [i + 1]
            for (j, other) in hypothesis.enumerated() {
                next.append(min(previous[j + 1] + 1, next[j] + 1, previous[j] + (word == other ? 0 : 1)))
            }
            previous = next
        }
        return Double(previous.last ?? 0) / Double(max(1, reference.count))
    }

    @Test func scoresInsertionsDeletionsAndProperNounSubstitutions() {
        #expect(Self.wordErrorRate(expected: "Play In Our Time", actual: "play in our time.") == 0)
        #expect(Self.wordErrorRate(expected: "Follow Saloni Dattani", actual: "Follow Saloni attorney") == 1.0 / 3)
        #expect(Self.wordErrorRate(expected: "go back two minutes", actual: "go back") == 0.5)
    }
}
