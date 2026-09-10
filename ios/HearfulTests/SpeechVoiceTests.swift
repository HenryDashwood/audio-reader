import AVFoundation
import Testing

@testable import Hearful

@Suite("Speech voice selection")
struct SpeechVoiceTests {
    @Test func namesAppleQualityTiers() {
        #expect(SpeechVoice.qualityName(.premium) == "Premium")
        #expect(SpeechVoice.qualityName(.enhanced) == "Enhanced")
        #expect(SpeechVoice.qualityName(.default) == "Default")
    }

    @Test func pickerContainsEveryInstalledVoice() {
        let installed = Set(AVSpeechSynthesisVoice.speechVoices().map(\.identifier))
        let displayed = Set(SpeechVoice.installedVoices().map(\.identifier))

        #expect(displayed == installed)
    }

    @Test func pickerOrdersHigherQualityVoicesFirst() {
        let qualities = SpeechVoice.installedVoices().map(\.quality.rawValue)

        #expect(zip(qualities, qualities.dropFirst()).allSatisfy { pair in
            pair.0 >= pair.1
        })
    }

    @Test @MainActor func backgroundSnapshotContainsTheVoicePickerValues() async {
        let snapshot = await SpeechVoice.settingsSnapshot()
        let installed = SpeechVoice.installedVoices()
        #expect(snapshot.choices.map(\.id) == installed.map(\.identifier))
        #expect(snapshot.choices.map(\.label) == installed.map {
            [$0.name, $0.language, SpeechVoice.qualityName($0.quality)].joined(separator: " · ")
        })
        #expect(snapshot.selectedID == SpeechVoice.current?.identifier ?? "")
    }
}
