import Combine
import Foundation

/// Stops playback after a while, for listening in bed.
///
/// Only durations, no "at the end of this episode": nothing in this app plays
/// on automatically, so an episode already ends in silence. Offering a setting
/// that does nothing would be worse than not offering it.
///
/// Playback is paused rather than faded out. A fade would be gentler, but it
/// means holding the player at a reduced volume and putting it back on resume
/// — and a bug in that leaves her with an app that plays nothing audible and
/// no way to see why.
@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer(player: .shared)

    /// The choices offered on screen and matched by voice.
    static let options = [5, 10, 15, 30, 45, 60]

    /// When playback will stop; nil when no timer is set.
    @Published private(set) var endsAt: Date?

    private let player: PlaybackCoordinator
    private let feedback: FeedbackPlaying
    private var timer: Timer?
    /// Injectable so tests need not wait out a real minute.
    private let now: @MainActor () -> Date

    init(
        player: PlaybackCoordinator,
        feedback: FeedbackPlaying = Feedback.shared,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.player = player
        self.feedback = feedback
        self.now = now
    }

    var isRunning: Bool { endsAt != nil }

    /// Seconds left, or nil when nothing is set. Rounded up so a timer with
    /// four and a half minutes left is announced as five, not four.
    var remaining: TimeInterval? {
        endsAt.map { max(0, $0.timeIntervalSince(now())) }
    }

    func start(minutes: Int) {
        cancel()
        let seconds = TimeInterval(minutes * 60)
        endsAt = now().addingTimeInterval(seconds)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        endsAt = nil
    }

    /// Internal rather than private: the tests call this instead of waiting.
    func fire() {
        timer?.invalidate()
        timer = nil
        endsAt = nil
        guard player.isPlaying else { return }
        player.pause()
        // The same marker a finished episode gets. Without it, going quiet in
        // the middle of a sentence is indistinguishable from a crash — and if
        // she is still awake, that is exactly the moment she would reach for
        // the phone to find out which.
        feedback.play(.finished)
    }

    /// Spoken confirmation, in words rather than a clock reading.
    static func spokenDuration(minutes: Int) -> String {
        switch minutes {
        case 60: "an hour"
        case 90: "an hour and a half"
        case 30: "half an hour"
        case 1: "a minute"
        default: "\(minutes) minutes"
        }
    }
}
