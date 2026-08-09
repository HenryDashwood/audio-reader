import AVFoundation

/// The one voice the whole app speaks with.
///
/// `AVSpeechSynthesisVoice(language:)` returns the compact default even when
/// a far better enhanced or premium voice is installed. Picking the highest
/// quality installed British English voice explicitly means articles and
/// spoken confirmations always sound the same — and as good as the device
/// can manage. (Settings → Accessibility → Spoken Content → Voices is where
/// better ones are downloaded, free.)
nonisolated enum SpeechVoice {
    /// Cached: the installed-voices list cannot change without leaving the
    /// app, and enumerating it per utterance is waste.
    static let best: AVSpeechSynthesisVoice? = {
        let british = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-GB" }
        return british.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }()
}
