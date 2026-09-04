import AVFoundation

/// What a system audio event means for playback.
///
/// The raw notifications carry integers in a dictionary; turning them into
/// these three cases at the edge means the interesting part — what we do
/// about them — is testable without taking a phone call mid-episode.
enum AudioSessionEvent: Equatable {
    /// A call, an alarm, Siri: something else has taken the audio.
    case interrupted
    /// It has finished. `shouldResume` is the system's opinion on whether
    /// picking up where we left off is welcome; a call ending says yes, the
    /// user starting another app's audio says no.
    case interruptionEnded(shouldResume: Bool)
    /// Headphones unplugged, or Bluetooth walked out of range.
    case outputDeviceDisconnected
}

/// Reads AVAudioSession's notification payloads.
enum AudioSessionEventReader {
    static func interruption(from userInfo: [AnyHashable: Any]) -> AudioSessionEvent? {
        guard let raw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return nil }

        switch type {
        case .began:
            // Since iOS 17 the system can describe a route going away — the
            // AirPods coming out — as an interruption rather than a route
            // change, and one that never "ends". Treated as the disconnection
            // it is, so a later call ending cannot put the episode back on
            // through the speaker. The microphone being muted is a recording
            // matter and no reason to touch playback.
            if let rawReason = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
                let reason = AVAudioSession.InterruptionReason(rawValue: rawReason)
            {
                switch reason {
                case .routeDisconnected: return .outputDeviceDisconnected
                case .builtInMicMuted: return nil
                default: break
                }
            }
            return .interrupted
        case .ended:
            let options = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt).map(
                AVAudioSession.InterruptionOptions.init(rawValue:))
            return .interruptionEnded(shouldResume: options?.contains(.shouldResume) ?? false)
        @unknown default:
            return nil
        }
    }

    static func routeChange(from userInfo: [AnyHashable: Any]) -> AudioSessionEvent? {
        guard let raw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return nil }
        // Only the disconnection matters. Plugging headphones *in* is not a
        // reason to stop, and the other reasons are routine.
        return reason == .oldDeviceUnavailable ? .outputDeviceDisconnected : nil
    }
}

/// Decides what playback should do about a system audio event.
///
/// The one piece of state worth keeping is whether she wanted sound when the
/// interruption arrived: resuming after a call is right only if she was
/// listening before it came in, and silently starting an episode because a
/// timer went off would be worse than doing nothing.
///
/// `wantsPlayback` is intent — "she has asked for this to be playing" — not
/// whether audio is coming out at this instant. The two come apart during an
/// interruption, which is precisely when this runs.
struct InterruptionPolicy {
    enum Action: Equatable {
        case pause
        case resume
        case nothing
    }

    private(set) var wasPlayingWhenInterrupted = false
    /// Between a begin and its end. One phone call can begin more than once —
    /// the ring, then the answer — and only the first begin saw her intent;
    /// by the second, playback is already paused, and reading intent again
    /// would conclude she had not been listening and never resume.
    private(set) var isInterrupted = false

    mutating func decide(_ event: AudioSessionEvent, wantsPlayback: Bool) -> Action {
        switch event {
        case .interrupted:
            guard !isInterrupted else { return .nothing }
            isInterrupted = true
            wasPlayingWhenInterrupted = wantsPlayback
            return wantsPlayback ? .pause : .nothing

        case .interruptionEnded(let shouldResume):
            let resuming = wasPlayingWhenInterrupted && shouldResume
            reset()
            return resuming ? .resume : .nothing

        case .outputDeviceDisconnected:
            // Whatever happens next, it must not be resumed automatically:
            // the headphones coming out means the room can hear it.
            wasPlayingWhenInterrupted = false
            return wantsPlayback ? .pause : .nothing
        }
    }

    /// She has taken over: pressed play or pause herself, or put something
    /// else on. Whatever an interruption remembered is void. The system
    /// promises no end for every begin — an app suspended during a long call
    /// gets none — and without this the remembered intent would sit waiting
    /// for the next unrelated end, Siri hours later, to start the episode on
    /// its own.
    mutating func reset() {
        isInterrupted = false
        wasPlayingWhenInterrupted = false
    }
}
