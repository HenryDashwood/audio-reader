import AVFoundation

/// The one voice the whole app speaks with — articles, confirmations, errors.
///
/// She picks it in Settings; until she does, the default is the best-quality
/// *natural* English voice installed. "Natural" matters: iOS also ships the
/// Eloquence formant voices and the novelty voices, which tie with the
/// standard voice on the quality enum but sound robotic and clipped — an
/// arbitrary tie-break once landed on one, which is exactly the regression a
/// naive "highest quality" pick produces. They stay available in the picker;
/// they just never win by default.
nonisolated enum SpeechVoice {
    static let storageKey = "HearfulSpeechVoice"

    /// The voice to speak with right now.
    static var current: AVSpeechSynthesisVoice? {
        if let identifier = UserDefaults.standard.string(forKey: storageKey),
            let chosen = AVSpeechSynthesisVoice(identifier: identifier)
        {
            return chosen
        }
        return fallback
    }

    static func select(identifier: String) {
        UserDefaults.standard.set(identifier, forKey: storageKey)
    }

    /// Where a chosen Kokoro voice is remembered.
    static let naturalVoiceKey = "HearfulNaturalVoice"

    /// The natural voice she has chosen, if any.
    ///
    /// Kept apart from the system voice rather than mixed into the same key:
    /// turning the natural voice off has to put her back on exactly the Apple
    /// voice she had before, and the spoken confirmations go on using that
    /// one either way — they are a sentence long, where the wait to render is
    /// worse than the voice is better.
    static var naturalVoice: KokoroVoice? {
        guard let identifier = UserDefaults.standard.string(forKey: naturalVoiceKey),
            let name = KokoroVoice.name(fromIdentifier: identifier)
        else { return nil }
        return KokoroVoice.named(name)
    }

    static func selectNatural(_ voice: KokoroVoice?) {
        if let voice {
            UserDefaults.standard.set(voice.identifier, forKey: naturalVoiceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: naturalVoiceKey)
        }
    }

    /// Every installed English voice, best first: quality descending, natural
    /// voices before Eloquence/novelty, then by name. What the picker shows.
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if isNatural(a) != isNatural(b) { return isNatural(a) }
                return a.name < b.name
            }
    }

    static func isNatural(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let identifier = voice.identifier.lowercased()
        return !identifier.contains("eloquence")
            && !identifier.contains("speech.synthesis.voice")  // Zarvox, Trinoids et al.
    }

    /// Best natural British voice, else best natural English voice, else the
    /// plain system default — the app's original behaviour.
    private static var fallback: AVSpeechSynthesisVoice? {
        let natural = englishVoices().filter(isNatural)
        return natural.first { $0.language == "en-GB" && $0.quality != .default }
            ?? natural.first { $0.quality != .default }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }
}
