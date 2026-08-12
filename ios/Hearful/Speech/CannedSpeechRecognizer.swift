import Foundation

/// Development-only stand-in for the microphone, so the network and playback
/// path can be exercised end to end without anyone speaking. Enabled by
/// setting HEARFUL_FAKE_TRANSCRIPT in the scheme's environment; never active
/// in a normal build.
@MainActor
final class CannedSpeechRecognizer: SpeechRecognizing {
    let transcript: String

    init(transcript: String) {
        self.transcript = transcript
    }

    func listen(onReady: @MainActor () -> Void) async throws -> String {
        try? await Task.sleep(nanoseconds: 300_000_000)  // feel like real capture
        onReady()
        return transcript
    }

    func cancel() {}
}
