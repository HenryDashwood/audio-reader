import Foundation
import Testing
@testable import Hearful

struct VoiceConversationPreferencesTests {
    @Test func defaultsAndSavedChoices() throws {
        let name = "voice-preferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(VoiceConversationPreferences.load(from: defaults).keepListening)
        #expect(VoiceConversationPreferences.load(from: defaults).followUpWait == 15)
        defaults.set(false, forKey: VoiceConversationPreferences.keepListeningKey)
        defaults.set(30, forKey: VoiceConversationPreferences.followUpWaitKey)
        #expect(!VoiceConversationPreferences.load(from: defaults).keepListening)
        #expect(VoiceConversationPreferences.load(from: defaults).followUpWait == 30)
        defaults.set(-10, forKey: VoiceConversationPreferences.followUpWaitKey)
        #expect(VoiceConversationPreferences.load(from: defaults).followUpWait == 15)
    }

    @Test(arguments: ["That’s all.", "That's all!", "  Goodbye Magpie.  ", "End the conversation", "That's all, thanks."])
    func recognisesGoodbyes(phrase: String) {
        #expect(VoiceConversationPreferences.endsConversation(phrase))
    }

    @Test(arguments: ["Stop playing", "That's all about history", "Play Goodbye Yellow Brick Road", "Thanks", "Stop in twenty minutes"])
    func doesNotMistakeRequestsForGoodbyes(phrase: String) {
        #expect(!VoiceConversationPreferences.endsConversation(phrase))
    }
}
