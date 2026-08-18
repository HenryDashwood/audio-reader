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

@Suite("Listening progress")
struct ListeningProgressTests {
    private func progress(
        position: Double?, duration: Int? = 3600, completed: Bool? = nil
    ) -> ListeningProgress {
        ListeningProgress(
            positionSeconds: position, durationSeconds: duration, completed: completed)
    }

    @Test func neverPlayedIsUnplayed() {
        #expect(progress(position: nil) == .unplayed)
    }

    @Test func finishedIsPlayed() {
        #expect(progress(position: 3500, completed: true) == .played)
    }

    @Test func partWayThroughReportsWhatIsLeft() {
        #expect(progress(position: 1200) == .inProgress(remainingSeconds: 2400))
    }

    @Test func theFirstFewSecondsDoNotCount() {
        // The backend records a position the moment anything plays, including
        // the second before she changed her mind. Calling that "59 min left"
        // would fill the list with episodes she never really started.
        #expect(progress(position: 20) == .unplayed)
    }

    @Test func theLastMinuteCountsAsFinished() {
        // Sending her back into an outro is worse than calling it done.
        #expect(progress(position: 3570) == .played)
    }

    @Test func anUnknownDurationCannotBeInProgress() {
        // Articles have no duration until their text is fetched; "left" is
        // not a number we have.
        #expect(progress(position: 300, duration: nil) == .unplayed)
    }

    @Test func labelsReadAsSentences() {
        #expect(progress(position: nil).label == nil)
        #expect(progress(position: 1200, completed: true).label == "Played")
        #expect(progress(position: 3000).label == "10 min left")
    }

    @Test func remainingTimeRoundsToWholeMinutes() {
        #expect(progress(position: 3480, duration: 3600).label == "2 min left")
        #expect(progress(position: 3500, duration: 3600).label == "2 min left")
    }

    @Test func neverSaysZeroMinutesLeft() {
        // Just over a minute to go still rounds up to one, and anything under
        // a minute has already been called played.
        #expect(progress(position: 3539, duration: 3600).label == "1 min left")
        #expect(progress(position: 3541, duration: 3600).label == "Played")
    }
}

@Suite("Continue listening selection")
struct ContinueListeningTests {
    private func episode(position: Double?, completed: Bool? = nil) -> Episode {
        Episode(
            id: 1, title: "One", description: nil,
            audioURL: URL(string: "https://cdn.example.com/1.mp3"), durationSeconds: 3600,
            publishedAt: nil, link: nil, imageURL: nil, positionSeconds: position,
            completed: completed)
    }

    @Test func onlyPartlyHeardEpisodesQualify() {
        #expect(episode(position: 1200).listeningProgress.hasStarted)
    }

    @Test func untouchedAndFinishedEpisodesDoNot() {
        // The section is a way back into something interrupted, not a history.
        #expect(!episode(position: nil).listeningProgress.hasStarted)
        #expect(!episode(position: 1200, completed: true).listeningProgress.hasStarted)
        #expect(!episode(position: 5).listeningProgress.hasStarted)
    }
}

@Suite("What a feed's items are called")
struct FeedItemNamingTests {
    private func show(count: Int, article: Bool?) -> Show {
        Show(
            id: 1, title: "Notes on Progress", description: nil, artworkURL: nil,
            episodeCount: count, isArticleFeed: article)
    }

    @Test func aBlogHasPosts() {
        #expect(show(count: 33, article: true).itemCountLabel == "33 posts")
        #expect(show(count: 33, article: true).itemsSectionTitle == "Posts")
    }

    @Test func aPodcastHasEpisodes() {
        #expect(show(count: 25, article: false).itemCountLabel == "25 episodes")
        #expect(show(count: 25, article: false).itemsSectionTitle == "Episodes")
    }

    // Anything cached before the field existed, or from an older backend.
    @Test func anUnknownFeedIsCalledAPodcast() {
        #expect(show(count: 25, article: nil).itemCountLabel == "25 episodes")
    }

    @Test func oneIsNotPluralised() {
        #expect(show(count: 1, article: true).itemCountLabel == "1 post")
        #expect(show(count: 1, article: false).itemCountLabel == "1 episode")
    }
}
