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
    /// Cuts the junk off both ends of a rendered segment.
    ///
    /// The model brackets its speech with two different artefacts, and both
    /// are audible when segments are played one after another:
    ///
    /// - a **decaying low tone** after the last word, up to 0.75s of it;
    /// - a **periodic buzz** before the first word, up to 0.9s, with energy
    ///   only at DC, 4.8kHz and 9.6kHz. It is quiet — a fifth of the speech
    ///   level — but that 9.6kHz component is piercing, and it is what a
    ///   listener describes as a high-pitched note between sentences.
    ///
    /// Neither can be found by loudness: the tone is louder than the speech
    /// around it, the buzz much quieter. Nor by high-frequency energy, which
    /// was the first attempt here — over half the buzz's energy is above 4kHz,
    /// so gating on that kept it.
    ///
    /// What separates them is the **speech band**. Voiced or unvoiced, speech
    /// always has energy between 300Hz and 4kHz, where the formants are. The
    /// measured buzz has *exactly none* there, and neither does the tone. So
    /// the test is a band-pass and a gate on the median frame energy, which
    /// removes both and leaves every clean segment untouched to within 10ms.
    ///
    /// Returns itself unchanged if nothing passes the gate, so a quiet or
    /// unusual render is never emptied out.
    func trimmedToSpeech() -> KokoroAudio {
        guard sampleRate > 0, samples.count > Self.window else { return self }

        var filtered = samples
        for _ in 0..<Self.stages { Self.bandPass(&filtered, sampleRate: sampleRate) }

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

        // Speech has to *persist* to count. A single frame over the gate is
        // the buzz's own onset — it steps up from nothing, and a step is
        // broadband, so one frame of it looks exactly like a consonant. That
        // one frame was enough to make the whole buzz survive.
        guard let firstLoud = Self.startOfRun(in: energies, over: gate, reversed: false),
            let lastLoud = Self.startOfRun(in: energies, over: gate, reversed: true)
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

    /// The first frame of the earliest (or latest) unbroken run of frames
    /// above the gate, or nil if no run is long enough.
    private static func startOfRun(
        in energies: [Float], over gate: Float, reversed: Bool
    ) -> Int? {
        let order = reversed ? Array(energies.indices.reversed()) : Array(energies.indices)
        var run = 0
        for index in order {
            run = energies[index] > gate ? run + 1 : 0
            if run >= minimumRun {
                return reversed ? index + minimumRun - 1 : index - minimumRun + 1
            }
        }
        return nil
    }

    /// One RBJ band-pass biquad, in place. Two of these are steep enough to
    /// reject a 9.6kHz buzz; cascaded one-pole filters are not — they leak
    /// enough of it to pass the gate.
    private static func bandPass(_ signal: inout [Float], sampleRate: Double) {
        let omega = 2 * Double.pi * centre / sampleRate
        let alpha = sin(omega) / (2 * quality)
        let norm = 1 + alpha
        let b0 = Float(alpha / norm)
        let b2 = Float(-alpha / norm)
        let a1 = Float(-2 * cos(omega) / norm)
        let a2 = Float((1 - alpha) / norm)

        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for index in signal.indices {
            let input = signal[index]
            let output = b0 * input + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = input
            y2 = y1; y1 = output
            signal[index] = output
        }
    }

    /// Centre of the speech band the gate listens to.
    private static let centre = 1100.0
    private static let quality = 0.8
    private static let stages = 2
    /// Frames of speech-band energy needed before it counts as speech —
    /// about 30ms. Two is enough to reject the onset transient; three leaves
    /// margin, and measures identically on every segment tested.
    private static let minimumRun = 3
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
