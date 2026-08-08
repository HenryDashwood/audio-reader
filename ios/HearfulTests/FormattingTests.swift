import Foundation
import Testing

@testable import Hearful

@Suite("Duration formatting")
struct DurationFormattingTests {
    @Test func showsMinutesAndSecondsUnderAnHour() {
        #expect(formatDuration(65) == "1:05")
        #expect(formatDuration(599) == "9:59")
    }

    @Test func showsHoursWhenThereAreSome() {
        #expect(formatDuration(3661) == "1:01:01")
    }

    @Test func roundsDownRatherThanShowingFractions() {
        #expect(formatDuration(65.9) == "1:05")
    }

    @Test func handlesZeroAndNonsense() {
        // An unloaded stream reports zero or NaN; neither should render as text.
        #expect(formatDuration(0) == "0:00")
        #expect(formatDuration(.nan) == "0:00")
        #expect(formatDuration(-5) == "0:00")
    }
}

@Suite("Episode length labels")
struct EpisodeLengthTests {
    @Test func roundsToWholeMinutes() {
        #expect(formatLength(seconds: 3209) == "53 min")
        #expect(formatLength(seconds: 60) == "1 min")
    }

    @Test func missingLengthHasNoLabel() {
        #expect(formatLength(seconds: nil) == nil)
    }

    @Test func veryShortEpisodesStillReadSensibly() {
        #expect(formatLength(seconds: 20) == "1 min")
    }
}
