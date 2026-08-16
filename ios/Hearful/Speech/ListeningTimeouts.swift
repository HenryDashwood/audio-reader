import Foundation
import UIKit

/// Three different silences that are easy to mistake for one.
///
/// Before she has said anything, quiet means "still gathering her thought" and
/// deserves patience. Once she has finished a phrase the recogniser has
/// committed to, the same quiet means "finished", and every further moment is
/// dead air before the episode starts.
///
/// The third is the one that was missing. While the recogniser is still
/// revising what it heard, quiet means neither of those — it means the
/// transcript is not yet safe to act on. Ending there sends a half-formed
/// guess: "play the In Our Time episode about Athelstan" left as
/// "play the in our stand", which names a show and no episode, so the app
/// dutifully played that show's newest episode. She had not finished
/// speaking and the recogniser had not finished listening.
struct ListeningTimeouts {
    /// How long to wait for her to begin.
    let beforeFirstWords: TimeInterval
    /// How long a pause counts as the end of the request, once the transcript
    /// has settled.
    let afterLastWords: TimeInterval
    /// How long to keep waiting while the recogniser is still revising. A
    /// backstop rather than an expected wait: it applies only when the
    /// transcript never settles, and it is the difference between a slow
    /// answer and a wrong one.
    let whileStillRevising: TimeInterval

    /// With VoiceOver on, the opening wait has to outlast VoiceOver itself. It
    /// announces the screen as the microphone opens, and nobody talks over
    /// their own screen reader — so she listens, waits for it to finish, and
    /// only then starts composing. Eight seconds can elapse before she has
    /// been given a chance to say anything.
    init(
        beforeFirstWords: TimeInterval? = nil,
        afterLastWords: TimeInterval = 2.0,
        whileStillRevising: TimeInterval = 4.0
    ) {
        self.beforeFirstWords =
            beforeFirstWords ?? (UIAccessibility.isVoiceOverRunning ? 15.0 : 8.0)
        self.afterLastWords = afterLastWords
        self.whileStillRevising = whileStillRevising
    }

    /// How long silence may last before the request is treated as complete.
    ///
    /// `isSettled` is whether the recogniser has committed to what it has
    /// transcribed so far, rather than still holding a guess it may rewrite.
    func interval(hasHeardSpeech: Bool, isSettled: Bool) -> TimeInterval {
        guard hasHeardSpeech else { return beforeFirstWords }
        return isSettled ? afterLastWords : whileStillRevising
    }
}
