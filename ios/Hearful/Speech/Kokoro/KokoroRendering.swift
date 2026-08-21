import Foundation

/// A stretch of synthesised speech: mono float samples and the rate they were
/// made at. Kokoro produces 24kHz; nothing here assumes that.
nonisolated struct KokoroAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

nonisolated extension KokoroAudio {
    /// Trims the silence the model leaves either side of a segment.
    ///
    /// Every render arrives with about 0.29s of digital silence before the
    /// first word and 0.68s after the last. One utterance played on its own —
    /// the way the upstream demo works — that is unnoticeable. Played as a
    /// paragraph split into segments it is nearly a second of dead air at
    /// every join, which is the only reason anything here touches the audio.
    ///
    /// It is deliberately a silence trim and not a speech detector. An
    /// earlier version classified frames as speech or not, and every version
    /// of that idea clipped real sounds: a word-initial /s/ has almost no
    /// energy where vowels do, and a fade applied at the cut ate the start of
    /// the first syllable. Silence is unambiguous, so this cannot take
    /// anything audible with it — the cut lands in a stretch that is already
    /// below hearing, and no fade is needed because there is no discontinuity
    /// to smooth.
    ///
    /// Artefacts in the audio are not this function's job. They come from
    /// giving the model too much text at once, and are prevented by
    /// ``KokoroSynthesizer/segmentCharacterLimit``.
    func trimmedSilence() -> KokoroAudio {
        guard sampleRate > 0, !samples.isEmpty else { return self }

        let threshold = Self.silenceThreshold
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
            let last = samples.lastIndex(where: { abs($0) > threshold })
        else { return self }

        // A little silence is kept either side: enough that nothing is ever
        // shaved off an onset, far too little to hear as a gap.
        let margin = Int(Self.marginSeconds * sampleRate)
        let from = max(0, first - margin)
        let to = min(samples.count, last + 1 + margin)
        guard to > from, to - from < samples.count else { return self }

        return KokoroAudio(samples: Array(samples[from..<to]), sampleRate: sampleRate)
    }

    /// About -54 dBFS. Below this nothing is audible, so cutting here cannot
    /// remove anything a listener would miss.
    private static let silenceThreshold: Float = 0.002
    private static let marginSeconds = 0.02
}

/// What KokoroSynthesizer needs from an inference engine, which is very
/// little: turn a piece of text into samples, and say which voices it has.
///
/// It exists so the synthesiser can be tested without MLX, without model
/// files and without a GPU — and so the MLX engine can be swapped for a Core
/// ML one later without the reader noticing.
/// nonisolated: the engine is an actor, and the project's default isolation
/// would otherwise pin this protocol to the main actor — where no actor could
/// conform to it, and inference would be back on the main thread.
nonisolated protocol KokoroRendering: Sendable {
    /// The voices this engine actually holds, which is the catalogue
    /// intersected with what is in the file on disk.
    func availableVoices() async -> [KokoroVoice]

    /// - Parameter speed: duration scaling, 1.0 being normal. Kokoro applies
    ///   it to the predicted phoneme durations, so faster speech sounds like
    ///   someone reading quickly rather than a tape played fast.
    func render(text: String, voice: KokoroVoice, speed: Float) async throws -> KokoroAudio
}

nonisolated enum KokoroEngineError: Error {
    /// The weights or the voice file are not on this device.
    case modelMissing
    /// The engine loaded, but has no style vector under that name.
    case voiceMissing(String)
}
