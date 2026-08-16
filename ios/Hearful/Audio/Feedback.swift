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
    /// An episode or article has reached its end.
    ///
    /// Without a marker, finishing sounds exactly like the app crashing, the
    /// connection dropping, or the phone going to sleep — silence, with no way
    /// to tell which. Deliberately a sound and not a sentence: hearing "that
    /// was the end of the episode" every time would wear out fast, and nothing
    /// starts automatically afterwards, so there is nothing to explain.
    case finished
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
    /// Rigid rather than another weight of the same thing: the go-ahead has to
    /// be told apart from the acknowledgement by character, not by guessing at
    /// strength, and they can arrive a couple of seconds apart.
    private let ready = UIImpactFeedbackGenerator(style: .rigid)
    private let notice = UINotificationFeedbackGenerator()

    init() {
        // Warming these avoids the first buzz arriving late.
        tick.prepare()
        impact.prepare()
        ready.prepare()
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
            // The go-ahead is no longer immediate — it waits for the
            // microphone route to actually come up, which can take a moment on
            // the first request after launch. Warm the generator that fires
            // then, so it is crisp rather than late.
            ready.prepare()
            AudioServicesPlaySystemSound(1113)  // begin record
        case .listening:
            // Felt as well as heard, because this is the one cue that has to
            // land. It fires the moment audio is genuinely flowing, so it is
            // the only honest signal that speaking now will be recorded — and
            // with the phone in her hand it arrives even when the tone is lost
            // under VoiceOver, a noisy room, or headphones she is not wearing.
            ready.impactOccurred()
            AudioServicesPlaySystemSound(1114)  // end record: "go ahead"
        case .failed:
            notice.notificationOccurred(.error)
        case .finished:
            // A short tone plus a buzz: audible with the phone in a pocket,
            // felt when it is in her hand. Any brief system sound would do —
            // this one is soft enough not to startle at the end of something
            // she may have fallen asleep to.
            notice.notificationOccurred(.success)
            AudioServicesPlaySystemSound(1057)
        }
    }
}
