import AudioToolbox
import UIKit

/// Short non-speech sounds. She cannot see the icon change, so these are the
/// only immediate signal that a tap registered — they play before any network
/// or speech work begins, which is what makes the wait feel short.
enum Cue: Equatable {
    /// The voice screen has come up — the one change she cannot see.
    case opened
    case acknowledged
    case listening
    case failed
}

@MainActor
protocol FeedbackPlaying {
    func play(_ cue: Cue)
}

@MainActor
final class Feedback: FeedbackPlaying {
    /// One instance app-wide, so the generators stay warm between taps.
    static let shared = Feedback()

    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notice = UINotificationFeedbackGenerator()

    init() {
        // Warming these avoids the first buzz arriving late.
        tick.prepare()
        impact.prepare()
        notice.prepare()
    }

    func play(_ cue: Cue) {
        switch cue {
        case .opened:
            // Lighter than the acknowledgement that follows it, so the two are
            // told apart: screen is up, then listening has begun.
            tick.impactOccurred()
        case .acknowledged:
            impact.impactOccurred()
            AudioServicesPlaySystemSound(1113)  // begin record
        case .listening:
            AudioServicesPlaySystemSound(1114)  // end record: "go ahead"
        case .failed:
            notice.notificationOccurred(.error)
        }
    }
}
