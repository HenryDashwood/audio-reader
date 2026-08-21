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
    /// Cuts the lead-in and the ring off a rendered segment.
    ///
    /// Every render comes back with roughly a quarter-second of silence before
    /// the first word, and — the audible part — a decaying pure tone after the
    /// last one, lasting up to three quarters of a second. Played one segment
    /// after another that is a held note every few words, which is exactly
    /// what it sounds like.
    ///
    /// Speech always carries energy above 1kHz; the ring is a low-frequency
    /// sinusoid and carries almost none. So the test is not loudness — the
    /// ring is loud — but where the high-frequency energy is. A one-pole
    /// high-pass and a gate on the median frame energy find the first and last
    /// frames that are really speech.
    ///
    /// Returns itself unchanged if nothing passes the gate, so a quiet or
    /// unusual render is never emptied out.
    func trimmedToSpeech() -> KokoroAudio {
        guard sampleRate > 0, samples.count > Self.window else { return self }

        // High-pass at 1kHz, two poles. One is not steep enough: it leaves a
        // 200Hz ring only ~14dB down, which is still above the gate.
        let coefficient = Float(exp(-2 * Double.pi * Self.cutoff / sampleRate))
        var filtered = samples
        for _ in 0..<Self.poles {
            var previousInput: Float = 0
            var previousOutput: Float = 0
            for index in filtered.indices {
                let input = filtered[index]
                previousOutput = coefficient * (previousOutput + input - previousInput)
                previousInput = input
                filtered[index] = previousOutput
            }
        }

        // Frame energies of what is left.
        var energies: [Float] = []
        var start = 0
        while start + Self.window <= filtered.count {
            var sum: Float = 0
            for index in start..<(start + Self.window) { sum += filtered[index] * filtered[index] }
            energies.append((sum / Float(Self.window)).squareRoot())
            start += Self.hop
        }
        let positive = energies.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return self }
        let gate = positive[positive.count / 2] * Self.gateFraction

        guard let firstLoud = energies.firstIndex(where: { $0 > gate }),
            let lastLoud = energies.lastIndex(where: { $0 > gate })
        else { return self }

        let guardSamples = Int(Self.guardSeconds * sampleRate)
        let from = max(0, firstLoud * Self.hop - guardSamples)
        let to = min(samples.count, lastLoud * Self.hop + Self.window + guardSamples)
        guard to > from else { return self }

        // Faded at both ends, or cutting into speech would click.
        var trimmed = Array(samples[from..<to])
        let fade = min(Int(Self.fadeSeconds * sampleRate), trimmed.count / 2)
        if fade > 0 {
            for index in 0..<fade {
                let ramp = Float(index) / Float(fade)
                trimmed[index] *= ramp
                trimmed[trimmed.count - 1 - index] *= ramp
            }
        }
        return KokoroAudio(samples: trimmed, sampleRate: sampleRate)
    }

    private static let cutoff = 1000.0
    private static let poles = 2
    private static let window = 512
    private static let hop = 128
    /// Fraction of the median frame energy that still counts as speech.
    private static let gateFraction: Float = 0.15
    /// Kept either side, so nothing is clipped off a quiet first consonant.
    private static let guardSeconds = 0.04
    private static let fadeSeconds = 0.01
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
