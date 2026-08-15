import Foundation
import UIKit

/// Two different waits that are easy to mistake for one.
///
/// Before she has said anything, quiet means "still gathering her thought" and
/// deserves patience. After she has spoken, the same quiet means "finished",
/// and every extra moment is dead air before the episode starts.
struct ListeningTimeouts {
    /// How long to wait for her to begin.
    let beforeFirstWords: TimeInterval
    /// How long a pause after speech counts as the end of the request.
    let afterLastWords: TimeInterval

    /// With VoiceOver on, the wait has to outlast VoiceOver itself. It
    /// announces the screen as the microphone opens, and nobody talks over
    /// their own screen reader — so she listens, waits for it to finish, and
    /// only then starts composing. Eight seconds can elapse before she has
    /// been given a chance to say anything.
    init(
        beforeFirstWords: TimeInterval? = nil,
        afterLastWords: TimeInterval = 1.0
    ) {
        self.beforeFirstWords =
            beforeFirstWords ?? (UIAccessibility.isVoiceOverRunning ? 15.0 : 8.0)
        self.afterLastWords = afterLastWords
    }

    func interval(hasHeardSpeech: Bool) -> TimeInterval {
        hasHeardSpeech ? afterLastWords : beforeFirstWords
    }
}
