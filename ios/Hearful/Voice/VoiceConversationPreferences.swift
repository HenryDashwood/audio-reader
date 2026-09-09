import Foundation

struct VoiceConversationPreferences {
    static let keepListeningKey = "Hearful.keepListeningAfterReplies"
    static let followUpWaitKey = "Hearful.followUpWait"
    static let defaultFollowUpWait: TimeInterval = 15
    static let waitOptions: [TimeInterval] = [10, 15, 20, 30]

    var keepListening = true
    var followUpWait: TimeInterval = defaultFollowUpWait

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let wait = defaults.double(forKey: followUpWaitKey)
        return Self(
            keepListening: defaults.object(forKey: keepListeningKey) as? Bool ?? true,
            followUpWait: waitOptions.contains(wait) ? wait : defaultFollowUpWait)
    }

    static func endsConversation(_ text: String) -> Bool {
        let phrase = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Exact phrases avoid treating "stop playing" or "that's all about
        // history" as a request to close the conversation.
        return ["that's all", "that is all", "that's all thanks", "that's all, thanks",
                "end conversation", "end the conversation", "goodbye", "goodbye magpie"].contains(phrase)
    }
}
