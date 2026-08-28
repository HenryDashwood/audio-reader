import SwiftUI

/// What she has done with an episode besides listen to it.
///
/// Two independent flags on the server rather than one state, because they
/// answer different questions — "have I heard this?" and "do I want to see
/// this?" — and only one of them is a claim about her listening. An episode
/// she skipped must never come back described as one she played; that is the
/// kind of quiet inaccuracy she has no way to check.
nonisolated enum EpisodeFiling: String, Sendable, Hashable {
    /// She has heard it.
    case played
    /// She does not want it, and has not heard it.
    case dismissed
    /// Neither: back in the list, from the beginning.
    case restored

    /// What the two flags become. A nil leaves that one as it was.
    var update: EpisodeStateUpdate {
        switch self {
        case .played: EpisodeStateUpdate(played: true, dismissed: nil)
        case .dismissed: EpisodeStateUpdate(played: nil, dismissed: true)
        case .restored: EpisodeStateUpdate(played: false, dismissed: false)
        }
    }

    /// True when the episode leaves the Latest list — which is the whole
    /// visible effect, and the reason everything here is announced.
    var hidesFromLatest: Bool { self != .restored }

    /// Which of these are worth offering on a row. An episode already filed
    /// has one useful action and it is the way back.
    static func available(for episode: Episode) -> [EpisodeFiling] {
        episode.completed == true || episode.dismissed == true ? [.restored] : [.played, .dismissed]
    }

    /// The swipe action's label, and what VoiceOver reads in the rotor.
    func actionTitle(for episode: Episode) -> String {
        switch self {
        case .played: episode.isArticle ? "Mark read" : "Mark played"
        case .dismissed: "Not interested"
        case .restored: "Put back"
        }
    }

    var systemImage: String {
        switch self {
        case .played: "checkmark.circle"
        case .dismissed: "xmark.circle"
        case .restored: "arrow.uturn.backward.circle"
        }
    }

    var tint: Color {
        switch self {
        case .played: .accentColor
        case .dismissed: .gray
        case .restored: .blue
        }
    }

    /// Said out loud once it has happened. Not decoration: the entire visible
    /// result is a row leaving a list, which is exactly the kind of change
    /// that reaches her only if something says so.
    func confirmation(for episode: Episode) -> String {
        switch self {
        case .played:
            episode.isArticle
                ? "Marked as read: \(episode.title)"
                : "Marked as played: \(episode.title)"
        case .dismissed: "Taken off your list: \(episode.title)"
        case .restored: "Back in your list: \(episode.title)"
        }
    }

    /// One episode's filing having changed, however it was changed.
    struct Change: Sendable {
        let episodeID: Int
        let filing: EpisodeFiling
    }

    /// Tells the rest of the app. The two things that have to hear about this
    /// are a list on screen and the position reporter, and neither can reach
    /// the other — the reporter belongs to the auth controller and exists
    /// whether or not any list has ever been drawn.
    @MainActor
    func broadcast(episodeID: Int) {
        NotificationCenter.default.post(
            name: .hearfulEpisodeFiled, object: Change(episodeID: episodeID, filing: self))
    }
}

/// Files an episode and says what happened.
///
/// Shared by the Latest list and a show's page, which differ only in what
/// they do with the row afterwards. Returns false when nothing changed, so
/// neither of them removes a row over a request that failed.
@MainActor
func fileEpisode(_ filing: EpisodeFiling, _ episode: Episode, api: HearfulAPIProtocol) async -> Bool
{
    do {
        try await api.setEpisodeState(
            episodeID: episode.id,
            played: filing.update.played,
            dismissed: filing.update.dismissed)
    } catch {
        // Announced rather than shown. A failed swipe leaves the row where it
        // was, which looks like nothing happening — and nothing happening is
        // also what a swipe she did not complete looks like.
        AccessibilityNotification.Announcement(
            (error as? APIError)?.spokenResponse ?? "Something went wrong.").post()
        return false
    }
    AccessibilityNotification.Announcement(filing.confirmation(for: episode)).post()
    filing.broadcast(episodeID: episode.id)
    return true
}

extension View {
    /// The filing actions for one episode row.
    ///
    /// Swipe actions, because VoiceOver surfaces them through the Actions
    /// rotor — the same gesture on every row of every list, and the only way
    /// to reach a control that is otherwise hidden behind a swipe you cannot
    /// see. Full swipe is off deliberately: a gesture that files an episode
    /// without stopping at a labelled button is one she cannot confirm before
    /// it happens.
    func episodeFilingActions(
        for episode: Episode, perform: @escaping (EpisodeFiling) -> Void
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            ForEach(EpisodeFiling.available(for: episode), id: \.self) { filing in
                Button {
                    perform(filing)
                } label: {
                    Label(filing.actionTitle(for: episode), systemImage: filing.systemImage)
                }
                .tint(filing.tint)
            }
        }
    }
}
