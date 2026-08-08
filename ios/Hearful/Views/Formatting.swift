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
