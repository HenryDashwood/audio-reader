import AVFoundation

/// The system voice used throughout the app for articles, confirmations and
/// errors. Settings exposes every speech voice available on the device.
nonisolated enum SpeechVoice {
    static let storageKey = "HearfulSpeechVoice"

    static var current: AVSpeechSynthesisVoice? {
        if let identifier = UserDefaults.standard.string(forKey: storageKey),
            let chosen = AVSpeechSynthesisVoice(identifier: identifier)
        {
            return chosen
        }
        UserDefaults.standard.removeObject(forKey: storageKey)
        return fallback
    }

    static func select(identifier: String) {
        guard AVSpeechSynthesisVoice(identifier: identifier) != nil else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        UserDefaults.standard.set(identifier, forKey: storageKey)
    }

    /// Every speech voice the system reports as available on this device.
    static func installedVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { first, second in
                if first.quality != second.quality {
                    return first.quality.rawValue > second.quality.rawValue
                }
                if first.language == "en-GB" && second.language != "en-GB" { return true }
                if first.language != "en-GB" && second.language == "en-GB" { return false }
                if first.language != second.language {
                    return first.language.localizedStandardCompare(second.language)
                        == .orderedAscending
                }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        case .default: "Default"
        @unknown default: "Default"
        }
    }

    /// Prefer an English voice for English articles even though Settings lets
    /// the user explicitly choose any installed language.
    private static var fallback: AVSpeechSynthesisVoice? {
        let voices = installedVoices().filter { $0.language.hasPrefix("en") }
        return voices.first { $0.language == "en-GB" && $0.quality == .premium }
            ?? voices.first { $0.quality == .premium }
            ?? voices.first { $0.language == "en-GB" }
            ?? voices.first
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }
}
