import Foundation

/// Refresh system suggestions at session and library boundaries, including
/// background intents that run before ContentView exists.
@MainActor
final class ShortcutLifecycle {
    static let shared = ShortcutLifecycle()
    private var observers: [NSObjectProtocol] = []
    private init() {
        for name in [Notification.Name.hearfulSubscriptionsChanged, .hearfulEpisodeFiled] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        ShortcutLibrary.shared.invalidate()
                        HearfulShortcuts.updateAppShortcutParameters()
                    }
                })
        }
        observers.append(
            NotificationCenter.default.addObserver(forName: .hearfulServerChanged, object: nil, queue: .main)
            { _ in
                MainActor.assumeIsolated { Self.resetSession() }
            })
    }
    static func resetSession() {
        ShortcutLibrary.shared.invalidate()
        ShortcutUndo.clear()
        ShortcutActionExecution.shared.clear()
        VoiceSessionContext.clearAll()
        VoicePrompt.clear()
        ShortcutNavigation.clear()
        PlaybackCoordinator.shared.clear()
        SleepTimer.shared.cancel()
        HearfulShortcuts.updateAppShortcutParameters()
    }
}
