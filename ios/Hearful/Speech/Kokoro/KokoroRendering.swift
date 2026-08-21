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
    /// Removes the noise the model puts around — and sometimes inside — its
    /// speech.
    ///
    /// Two artefacts, both audible when segments play back to back:
    ///
    /// - a **decaying low tone** after the last word, up to 0.75s of it, and
    ///   *louder* than the speech it follows;
    /// - a **periodic buzz** before the first word, up to 0.9s, with energy
    ///   only at DC, 4.8kHz and 9.6kHz. Quiet — a fifth of the speech level —
    ///   but that 9.6kHz component is piercing, and it is the squeak heard
    ///   between sentences. It appears on some segments and not others; on one
    ///   real article, two of the first six.
    ///
    /// Neither can be found by loudness, and neither by high-frequency energy
    /// (over half the buzz sits above 4kHz). What separates them is the
    /// **speech band**: speech always carries energy between 300Hz and 4kHz,
    /// where the formants are, and both artefacts carry effectively none.
    ///
    /// So this silences any stretch that is audible but has no speech in it,
    /// wherever it falls, and then trims the silence off the ends. Silencing
    /// rather than trimming matters: an edge trim can only ever shorten the
    /// buzz — whatever margin it leaves is more buzz — which is what three
    /// earlier attempts here did.
    ///
    /// Returns itself unchanged if nothing passes the gate, so a quiet or
    /// unusual render is never emptied out.
    func trimmedToSpeech() -> KokoroAudio {
        guard sampleRate > 0, samples.count > Self.window else { return self }

        var voiced = samples
        for _ in 0..<Self.stages { Self.bandPass(&voiced, sampleRate: sampleRate, centre: Self.centre, quality: Self.quality) }
        var sibilant = samples
        for _ in 0..<Self.stages {
            Self.bandPass(
                &sibilant, sampleRate: sampleRate, centre: Self.sibilantCentre,
                quality: Self.sibilantQuality)
        }

        var speechBand: [Float] = []
        var hissBand: [Float] = []
        var overall: [Float] = []
        var start = 0
        while start + Self.window <= voiced.count {
            var band: Float = 0
            var hiss: Float = 0
            var total: Float = 0
            for index in start..<(start + Self.window) {
                band += voiced[index] * voiced[index]
                hiss += sibilant[index] * sibilant[index]
                total += samples[index] * samples[index]
            }
            speechBand.append((band / Float(Self.window)).squareRoot())
            hissBand.append((hiss / Float(Self.window)).squareRoot())
            overall.append((total / Float(Self.window)).squareRoot())
            start += Self.hop
        }
        guard let bandMedian = Self.median(of: speechBand),
            let overallMedian = Self.median(of: overall)
        else { return self }

        let gate = bandMedian * Self.gateFraction
        let audible = overallMedian * Self.audibleFraction

        // A frame is speech if it is voiced *or* a sibilant. Formants live in
        // the 300Hz–4kHz band, but /s/, /f/ and /ʃ/ do not: measured here, the
        // /s/ opening "cinematic" put 50% of its energy in 5.5–8.5kHz and 0.4%
        // in the speech band, so a voiced-only test cut the word's first sound
        // off — audible as a dropped syllable.
        //
        // The sibilant test is a share of the frame's own energy, not a level.
        // The band is nearly empty through most of a segment, so a
        // median-relative gate there sits on the noise floor and lets the buzz
        // back in whatever the filter's shape.
        let isSpeech = (0..<speechBand.count).map { index in
            speechBand[index] > gate
                || (hissBand[index] > Self.sibilantShare * overall[index]
                    && overall[index] > audible)
        }
        var cleaned = samples

        // Anything audible with no speech in it is noise, wherever it is.
        // A frame is junk only if its whole window lacks speech-band energy,
        // so silencing the run's full extent cannot take speech with it.
        var runStart: Int?
        for index in 0...isSpeech.count {
            let isJunk = index < isSpeech.count && !isSpeech[index] && overall[index] > audible
            if isJunk {
                if runStart == nil { runStart = index }
            } else if let first = runStart {
                let last = index - 1
                if (last - first + 1) * Self.hop >= Int(Self.minimumJunk * sampleRate) {
                    Self.silence(
                        &cleaned, from: first * Self.hop,
                        to: min(cleaned.count, last * Self.hop + Self.window),
                        sampleRate: sampleRate)
                }
                runStart = nil
            }
        }

        // What is left of the ends is silence, so cut it. Speech has to
        // persist for a few frames to count: a single frame over the gate is
        // an onset transient, which is broadband and looks like a consonant.
        guard let firstLoud = Self.startOfRun(in: isSpeech, reversed: false),
            let lastLoud = Self.startOfRun(in: isSpeech, reversed: true)
        else { return self }

        let from = firstLoud * Self.hop
        let to = min(cleaned.count, lastLoud * Self.hop + Self.window)
        guard to > from else { return self }

        var trimmed = Array(cleaned[from..<to])
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

    /// Zeroes a range, ramping the speech either side of it so the join does
    /// not click. The ramps eat a few milliseconds of neighbouring speech,
    /// which is inaudible; leaving them off is not.
    private static func silence(
        _ signal: inout [Float], from: Int, to: Int, sampleRate: Double
    ) {
        guard to > from else { return }
        for index in from..<to { signal[index] = 0 }
        let ramp = Int(fadeSeconds * sampleRate)
        guard ramp > 0 else { return }
        for step in 0..<ramp {
            let scale = Float(step) / Float(ramp)
            let before = from - ramp + step
            if before >= 0 { signal[before] *= 1 - scale }
            let after = to + step
            if after < signal.count { signal[after] *= scale }
        }
    }

    private static func median(of values: [Float]) -> Float? {
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return nil }
        return positive[positive.count / 2]
    }

    /// The first frame of the earliest (or latest) unbroken run of frames
    /// above the gate, or nil if no run is long enough.
    private static func startOfRun(in speech: [Bool], reversed: Bool) -> Int? {
        let order = reversed ? Array(speech.indices.reversed()) : Array(speech.indices)
        var run = 0
        for index in order {
            run = speech[index] ? run + 1 : 0
            if run >= minimumRun {
                return reversed ? index + minimumRun - 1 : index - minimumRun + 1
            }
        }
        return nil
    }

    /// One RBJ band-pass biquad, in place. Two of these are steep enough to
    /// reject a 9.6kHz buzz; cascaded one-pole filters are not — they leak
    /// enough of it to pass the gate.
    private static func bandPass(
        _ signal: inout [Float], sampleRate: Double, centre: Double, quality: Double
    ) {
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
    /// Between the buzz's two lines at 4.8kHz and 9.6kHz, and where sibilants
    /// put their energy.
    private static let sibilantCentre = 6800.0
    private static let sibilantQuality = 3.0
    /// Share of a frame's energy in the sibilant band before it counts as one.
    /// Measured: an /s/ is around half, the buzz is none. Anything from 0.1 to
    /// 0.3 behaves identically on every segment tested.
    private static let sibilantShare: Float = 0.2
    private static let stages = 2
    /// Frames of speech-band energy needed before it counts as speech —
    /// about 30ms. Two is enough to reject an onset transient; three leaves
    /// margin, and measures identically on every segment tested.
    private static let minimumRun = 3
    private static let window = 512
    private static let hop = 128
    /// Fraction of the median frame energy that still counts as speech.
    private static let gateFraction: Float = 0.15
    /// Above this share of the median level, non-speech is loud enough to
    /// hear and worth silencing. Below it, it is already inaudible.
    private static let audibleFraction: Float = 0.05
    /// Shortest stretch of audible non-speech worth silencing.
    ///
    /// Deliberately well clear of a plosive. The closure in a /p/ or /t/ is
    /// audible, lasts 60–110ms and carries little speech-band energy, so a
    /// shorter threshold silences consonants — measured on this article, in
    /// every segment including a 34-character one. The buzz this guards
    /// against ran 310ms and 890ms. Nothing real sits in between.
    ///
    /// With the segment limit at 90 characters the model does not produce the
    /// buzz at all, so this is a safety net rather than the fix.
    private static let minimumJunk = 0.15
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
