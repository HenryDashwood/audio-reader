import Foundation

/// Clock-style position for a scrubber: 1:05, or 1:01:01 once past an hour.
func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

/// Rough length for a list row. Rounds up so a 20-second trailer is not "0 min".
func formatLength(seconds: Int?) -> String? {
    guard let seconds, seconds > 0 else { return nil }
    return "\(max(1, Int((Double(seconds) / 60).rounded()))) min"
}

/// Written equivalent of a podcast duration in a list row.
func formatWordCount(_ count: Int?) -> String? {
    guard let count, count > 0 else { return nil }
    return "\(count) \(count == 1 ? "word" : "words")"
}

/// How far through an episode she is, as a list row should describe it.
///
/// The backend stores a position for anything she has played, including the
/// few seconds before she changed her mind, so a row is only called
/// "in progress" once there is enough behind her to be worth going back to —
/// and once finished it is called played, not "0 min left".
enum ListeningProgress: Equatable {
    case unplayed
    case inProgress(remainingSeconds: Int)
    case played

    /// Below this, starting over costs nothing and "1 min left" would be a lie.
    static let startedThreshold: TimeInterval = 60

    init(positionSeconds: Double?, durationSeconds: Int?, completed: Bool?) {
        if completed == true {
            self = .played
            return
        }
        guard let positionSeconds, positionSeconds > Self.startedThreshold,
            let durationSeconds, durationSeconds > 0
        else {
            self = .unplayed
            return
        }
        let remaining = Double(durationSeconds) - positionSeconds
        // Within the last minute is effectively finished; an outro is not
        // something to send her back to.
        self = remaining <= 60 ? .played : .inProgress(remainingSeconds: Int(remaining))
    }

    /// Begun and not finished — the episodes worth offering to carry on with.
    var hasStarted: Bool {
        if case .inProgress = self { return true }
        return false
    }

    /// What the row says, and what VoiceOver reads.
    var label: String? {
        switch self {
        case .unplayed: nil
        case .played: "Played"
        case .inProgress(let remaining):
            "\(max(1, Int((Double(remaining) / 60).rounded()))) min left"
        }
    }
}

extension Episode {
    var listeningProgress: ListeningProgress {
        ListeningProgress(
            positionSeconds: positionSeconds, durationSeconds: durationSeconds,
            completed: completed)
    }
}

extension Show {
    /// What one item in this feed is called. A blog carries posts; a podcast
    /// carries episodes, and calling a written piece an episode is confusing
    /// read out loud as much as it is on screen.
    var itemNoun: String { isArticleFeed == true ? "post" : "episode" }

    /// The list of them, as a section header: "Posts", "Episodes".
    var itemsSectionTitle: String { isArticleFeed == true ? "Posts" : "Episodes" }

    /// How many there are, said the way the feed's own items are named.
    var itemCountLabel: String {
        "\(episodeCount) \(itemNoun)\(episodeCount == 1 ? "" : "s")"
    }
}
