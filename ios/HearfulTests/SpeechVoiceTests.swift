import AVFoundation
import Testing

@testable import Hearful

@Suite("Speech voice selection")
struct SpeechVoiceTests {
    @Test func acceptsApplePremiumEnglishVoices() {
        #expect(
            SpeechVoice.isEligible(
                identifier: "com.apple.voice.premium.en-GB.Jamie",
                language: "en-GB",
                quality: .premium
            ))
    }

    @Test func acceptsAppleEloquenceEnglishVoices() {
        #expect(
            SpeechVoice.isEligible(
                identifier: "com.apple.eloquence.en-US.Eddy",
                language: "en-US",
                quality: .default
            ))
    }

    @Test func rejectsEnhancedStandardThirdPartyAndNonEnglishVoices() {
        #expect(
            !SpeechVoice.isEligible(
                identifier: "com.apple.voice.enhanced.en-GB.Daniel",
                language: "en-GB",
                quality: .enhanced
            ))
        #expect(
            !SpeechVoice.isEligible(
                identifier: "com.apple.ttsbundle.siri_female_en-GB_compact",
                language: "en-GB",
                quality: .default
            ))
        #expect(
            !SpeechVoice.isEligible(
                identifier: "com.example.voice.en-GB.Custom",
                language: "en-GB",
                quality: .premium
            ))
        #expect(
            !SpeechVoice.isEligible(
                identifier: "com.apple.voice.premium.fr-FR.Thomas",
                language: "fr-FR",
                quality: .premium
            ))
    }

    @Test func pickerContainsOnlyEligibleVoices() {
        #expect(SpeechVoice.englishVoices().allSatisfy(SpeechVoice.isEligible))
    }
}
