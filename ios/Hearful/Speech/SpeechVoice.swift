import AVFoundation

/// The Apple voice used throughout the app for articles, confirmations and
/// errors. Settings exposes only installed English Premium and Eloquence
/// voices; lower-quality and third-party voices are deliberately excluded.
nonisolated enum SpeechVoice {
    static let storageKey = "HearfulSpeechVoice"

    static var current: AVSpeechSynthesisVoice? {
        if let identifier = UserDefaults.standard.string(forKey: storageKey),
            let chosen = AVSpeechSynthesisVoice(identifier: identifier),
            isEligible(chosen)
        {
            return chosen
        }
        UserDefaults.standard.removeObject(forKey: storageKey)
        return fallback
    }

    static func select(identifier: String) {
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier), isEligible(voice) else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        UserDefaults.standard.set(identifier, forKey: storageKey)
    }

    /// Installed English Apple voices that meet Hearful's quality floor.
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter(isEligible)
            .sorted { first, second in
                if first.quality != second.quality {
                    return first.quality.rawValue > second.quality.rawValue
                }
                if first.language == "en-GB" && second.language != "en-GB" { return true }
                if first.language != "en-GB" && second.language == "en-GB" { return false }
                return first.name < second.name
            }
    }

    static func isEligible(_ voice: AVSpeechSynthesisVoice) -> Bool {
        isEligible(
            identifier: voice.identifier,
            language: voice.language,
            quality: voice.quality
        )
    }

    static func isEligible(
        identifier: String,
        language: String,
        quality: AVSpeechSynthesisVoiceQuality
    ) -> Bool {
        identifier.hasPrefix("com.apple.")
            && language.hasPrefix("en")
            && (quality == .premium || isEloquence(identifier: identifier))
    }

    static func isEloquence(_ voice: AVSpeechSynthesisVoice) -> Bool {
        isEloquence(identifier: voice.identifier)
    }

    private static func isEloquence(identifier: String) -> Bool {
        identifier.localizedCaseInsensitiveContains("eloquence")
    }

    /// Prefer a British Premium voice, then another Premium voice, then
    /// Eloquence. The final system default is an accessibility safety net for
    /// a device on which no eligible voice has been installed yet.
    private static var fallback: AVSpeechSynthesisVoice? {
        let voices = englishVoices()
        return voices.first { $0.language == "en-GB" && $0.quality == .premium }
            ?? voices.first { $0.quality == .premium }
            ?? voices.first { $0.language == "en-GB" }
            ?? voices.first
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }
}
