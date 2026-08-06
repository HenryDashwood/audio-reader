import Foundation
import Testing

@testable import Hearful

@Suite("Listening timeouts")
struct ListeningTimeoutTests {
    @Test func waitsMuchLongerBeforeSheHasSaidAnything() {
        // The gap between tapping and starting to speak is not silence at the
        // end of a sentence, and must not be treated as one.
        let timeouts = ListeningTimeouts()
        #expect(timeouts.interval(hasHeardSpeech: false) > timeouts.interval(hasHeardSpeech: true))
    }

    @Test func opensWithEnoughTimeToGatherAThought() {
        #expect(ListeningTimeouts().interval(hasHeardSpeech: false) >= 6)
    }

    @Test func endsPromptlyOnceSheHasStopped() {
        #expect(ListeningTimeouts().interval(hasHeardSpeech: true) <= 1.5)
    }
}
