import AppIntents

/// Registers the spoken phrasings with Siri automatically — she never has to
/// open the Shortcuts app or configure anything.
///
/// Every phrase must contain `\(.applicationName)`; Apple requires it so Siri
/// knows which app is being addressed. Several wordings are listed because
/// people do not say the same thing twice.
struct HearfulShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // No parameters at all: the simplest thing Siri can match, and the
        // baseline for whether App Shortcuts are registering correctly.
        AppShortcut(
            intent: PlayLatestIntent(),
            phrases: [
                // Deliberately avoiding "play": Siri appears to route phrases
                // beginning with media verbs into its own music/podcast domain
                // before App Shortcuts are consulted, which is how an earlier
                // "play ... on Hearful" ended up in Spotify.
                "Catch up on \(.applicationName)",
                "Start listening on \(.applicationName)",
                "What's next on \(.applicationName)",
                "Latest on \(.applicationName)",
                // Kept so we can tell whether media-verb phrases work at all.
                "Play the latest on \(.applicationName)",
            ],
            shortTitle: "Play Latest",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayEpisodeIntent(),
            phrases: [
                // Parameterless first. Siri can only match a spoken parameter
                // against suggested episodes, so anything phrased loosely
                // ("the last Joe Rogan") has to arrive via its follow-up
                // question instead — which then resolves properly.
                "Play something on \(.applicationName)",
                "Listen to something on \(.applicationName)",
                "Play on \(.applicationName)",
                // These match when she names an episode close to its title.
                "Play \(\.$episode) on \(.applicationName)",
                "Listen to \(\.$episode) on \(.applicationName)",
            ],
            shortTitle: "Play Episode",
            systemImageName: "play.circle"
        )
    }
}
