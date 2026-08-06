import Foundation

/// Two different waits that are easy to mistake for one.
///
/// Before she has said anything, quiet means "still gathering her thought" and
/// deserves patience. After she has spoken, the same quiet means "finished",
/// and every extra moment is dead air before the episode starts.
struct ListeningTimeouts {
    /// How long to wait for her to begin.
    var beforeFirstWords: TimeInterval = 8.0
    /// How long a pause after speech counts as the end of the request.
    var afterLastWords: TimeInterval = 1.0

    func interval(hasHeardSpeech: Bool) -> TimeInterval {
        hasHeardSpeech ? afterLastWords : beforeFirstWords
    }
}
