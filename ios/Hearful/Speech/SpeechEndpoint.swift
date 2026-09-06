import Foundation

/// Endpointing uses the detector's audio timeline, not the arrival time of
/// text revisions. Only a settled local command earns the shorter pause.
struct SpeechEndpoint {
    private var lastSpeechEnd: Double?

    mutating func shouldFinish(
        speechDetected: Bool, audioEnd: Double, hasTranscript: Bool, settledControl: Bool
    ) -> Bool {
        guard audioEnd.isFinite else { return false }
        if speechDetected {
            lastSpeechEnd = max(lastSpeechEnd ?? 0, audioEnd)
            return false
        }
        guard hasTranscript, let lastSpeechEnd else { return false }
        return audioEnd - lastSpeechEnd >= (settledControl ? 0.7 : 1.5)
    }
}
