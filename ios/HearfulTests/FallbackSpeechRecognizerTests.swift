import Foundation
import Testing

@testable import Hearful

@MainActor
private final class ScriptedRecognizer: SpeechRecognizing {
    var result: Result<String, Error>
    private(set) var listenCount = 0
    private(set) var cancelCount = 0

    init(_ result: Result<String, Error>) { self.result = result }

    func listen(onReady: @MainActor () -> Void) async throws -> String {
        listenCount += 1
        let transcript = try result.get()
        onReady()
        return transcript
    }
    func cancel() { cancelCount += 1 }
}

private struct Boom: Error {}

private struct DroppedAfterReady: RecognitionFailureAfterCapture {}

@MainActor
private final class StartedThenFailedRecognizer: SpeechRecognizing {
    func listen(onReady: @MainActor () -> Void) async throws -> String {
        onReady()
        throw DroppedAfterReady()
    }

    func cancel() {}
}

@Suite("Fallback speech recognizer")
@MainActor
struct FallbackSpeechRecognizerTests {
    @Test func usesThePreferredRecognizerWhenItWorks() async throws {
        let preferred = ScriptedRecognizer(.success("play the seashells one"))
        let backup = ScriptedRecognizer(.success("wrong one"))
        let recognizer = FallbackSpeechRecognizer(preferred: preferred, backup: backup)

        let transcript = try await recognizer.listen()

        #expect(transcript == "play the seashells one")
        #expect(backup.listenCount == 0)  // never consulted
    }

    @Test func fallsBackWhenThePreferredOneFails() async throws {
        // On a device with no downloaded speech models the modern analyser
        // cannot start; the older recogniser still can.
        let preferred = ScriptedRecognizer(.failure(Boom()))
        let backup = ScriptedRecognizer(.success("play the seashells one"))
        let recognizer = FallbackSpeechRecognizer(preferred: preferred, backup: backup)

        let transcript = try await recognizer.listen()

        #expect(transcript == "play the seashells one")
        #expect(backup.listenCount == 1)
    }

    @Test func stopsFallingBackOnceThePreferredOneHasFailed() async throws {
        // Retrying a recogniser that cannot initialise wastes a second or two
        // on every command, which is a long time when you are waiting to talk.
        let preferred = ScriptedRecognizer(.failure(Boom()))
        let backup = ScriptedRecognizer(.success("ok"))
        let recognizer = FallbackSpeechRecognizer(preferred: preferred, backup: backup)

        _ = try await recognizer.listen()
        _ = try await recognizer.listen()

        #expect(preferred.listenCount == 1)
        #expect(backup.listenCount == 2)
    }

    @Test func propagatesTheErrorWhenBothFail() async {
        let recognizer = FallbackSpeechRecognizer(
            preferred: ScriptedRecognizer(.failure(Boom())),
            backup: ScriptedRecognizer(.failure(Boom())))

        await #expect(throws: (any Error).self) {
            _ = try await recognizer.listen()
        }
    }

    @Test func theGoAheadComesFromWhicheverRecognizerActuallyStarts() async throws {
        // The tone means "speak now", so it must come from the recogniser that
        // is listening — not from the one that failed on the way there.
        let recognizer = FallbackSpeechRecognizer(
            preferred: ScriptedRecognizer(.failure(Boom())),
            backup: ScriptedRecognizer(.success("play the seashells one")))

        var readyCount = 0
        _ = try await recognizer.listen { readyCount += 1 }

        #expect(readyCount == 1)
    }

    @Test func doesNotStartABackupAfterTheUserWasToldToSpeak() async {
        let backup = ScriptedRecognizer(.success("words the backup could not have heard"))
        let recognizer = FallbackSpeechRecognizer(
            preferred: StartedThenFailedRecognizer(), backup: backup)

        await #expect(throws: DroppedAfterReady.self) {
            _ = try await recognizer.listen()
        }
        #expect(backup.listenCount == 0)
    }

    @Test func cancelReachesBoth() async {
        let preferred = ScriptedRecognizer(.success("a"))
        let backup = ScriptedRecognizer(.success("b"))
        FallbackSpeechRecognizer(preferred: preferred, backup: backup).cancel()

        #expect(preferred.cancelCount == 1)
        #expect(backup.cancelCount == 1)
    }
}

private struct ColdMicrophone: TransientRecognitionFailure {
    var isTransient: Bool { true }
}

private struct NoAudioFormat: TransientRecognitionFailure {
    var isTransient: Bool { false }
}

@Suite("Fallback after a transient failure")
@MainActor
struct TransientFallbackTests {
    @Test func aTransientFailureDoesNotWriteTheGoodRecognizerOff() async throws {
        // The microphone failing to come up on the first request after launch
        // is about that attempt, not about the recogniser. Giving up on the
        // analyser over it would leave her on the weaker one until she next
        // restarts the app — for a fault that was gone by the second tap.
        let preferred = ScriptedRecognizer(.failure(ColdMicrophone()))
        let backup = ScriptedRecognizer(.success("ok"))
        let recognizer = FallbackSpeechRecognizer(preferred: preferred, backup: backup)

        _ = try await recognizer.listen()
        preferred.result = .success("play the Keats one")
        let second = try await recognizer.listen()

        #expect(preferred.listenCount == 2)
        #expect(second == "play the Keats one")
    }

    @Test func apermanentFailureStillWritesItOff() async throws {
        // A device with no compatible audio format will not grow one, and
        // retrying costs a wait before every request.
        let preferred = ScriptedRecognizer(.failure(NoAudioFormat()))
        let backup = ScriptedRecognizer(.success("ok"))
        let recognizer = FallbackSpeechRecognizer(preferred: preferred, backup: backup)

        _ = try await recognizer.listen()
        _ = try await recognizer.listen()

        #expect(preferred.listenCount == 1)
    }
}
