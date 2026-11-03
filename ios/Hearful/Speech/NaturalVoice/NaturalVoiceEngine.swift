import Accelerate
import CoreML
import Foundation
import os

nonisolated private let timing = Logger(subsystem: "com.henrydashwood.hearful", category: "natural-voice")

/// Kokoro on Core ML: a sentence of text in, 24 kHz audio and where each word
/// lands in it out.
///
/// The models and the steps between them are text-to-speech notebook 106's
/// `synthesize`. The front half (`tokens`, then `prosody`) and the sine source
/// run on the CPU in 32 bits; the decoder's body runs on the GPU at one of
/// three padded sizes, all in one model with its weights shared.
actor NaturalVoiceEngine {
    nonisolated static let sampleRate = 24_000.0
    /// Samples per frame: Kokoro decides durations in 25 ms steps.
    nonisolated static let frame = 600
    /// The body's sizes, in frames: 3.2, 6.4 and 12.8 seconds.
    nonisolated static let buckets = [128, 256, 512]

    struct Word: Sendable, Equatable {
        /// UTF-16 offsets into the text rendered.
        let characters: Range<Int>
        /// Sample offsets into the audio.
        let samples: Range<Int>
    }

    struct Sentence: Sendable {
        let samples: [Float]
        let words: [Word]
    }

    enum RenderError: Error, Equatable {
        /// Longer than the largest body: the caller splits it and tries again.
        case tooLong(frames: Int)
        case nothingToSay
    }

    let voice: NaturalVoice
    private let phonemizer: NaturalVoicePhonemizer
    private let vocabulary: [Unicode.Scalar: Int32]
    private let styles: [Float]  // 510 rows of 256: one per sentence length in phonemes
    private let tokens: MLModel
    private let prosody: MLModel
    private let source: MLModel
    private let folder: URL
    private var bodies: [Int: MLModel] = [:]
    private var random = SplitMix64(seed: 0x5EED)

    init(folder: URL, voice: NaturalVoice) throws {
        self.folder = folder
        self.voice = voice
        phonemizer = try NaturalVoicePhonemizer(folder: folder, british: voice.isBritish)
        let vocab = try JSONDecoder().decode(
            [String: Int32].self, from: Data(contentsOf: folder.appending(path: "vocab.json")))
        vocabulary = Dictionary(
            uniqueKeysWithValues: vocab.compactMap { key, id in key.unicodeScalars.first.map { ($0, id) } })
        let table = try Data(contentsOf: folder.appending(path: "voices/\(voice.id).bin"))
        styles = table.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        tokens = try MLModel(contentsOf: folder.appending(path: "tokens.mlmodelc"), configuration: cpu)
        prosody = try MLModel(contentsOf: folder.appending(path: "prosody.mlmodelc"), configuration: cpu)
        source = try MLModel(contentsOf: folder.appending(path: "source.mlmodelc"), configuration: cpu)
    }

    /// Speaks `text`, trimmed to the speech with a little either side.
    func render(_ text: String) throws -> Sentence {
        var clock = ContinuousClock.now
        var stages: [String] = []
        func lap(_ name: String) {
            stages.append("\(name) \((ContinuousClock.now - clock).components.attoseconds / 1_000_000_000_000_000 + (ContinuousClock.now - clock).components.seconds * 1000)ms")
            clock = ContinuousClock.now
        }
        let g2p = try phonemizer.phonemize(text)
        lap("g2p")
        let phonemes = Array(g2p.phonemes.unicodeScalars.prefix(510))  // Kokoro's limit, in code points
        let ids: [Int32] = [0] + phonemes.compactMap { vocabulary[$0] } + [0]
        guard ids.count > 2 else { throw RenderError.nothingToSay }
        let n = ids.count
        let style = Array(styles[(phonemes.count - 1) * 256 ..< phonemes.count * 256])

        // Per phoneme: duration features d (1, n, 640), text features t_en (1, 512, n), durations (1, n)
        let front = try predict(tokens, [
            "ids": MLMultiArray(MLShapedArray<Int32>(scalars: ids, shape: [1, n])),
            "style": MLMultiArray(MLShapedArray<Float>(scalars: style, shape: [1, 256])),
        ])
        lap("tokens")
        let d = try floats(front, "d")
        let tEn = try floats(front, "t_en")
        let frames = try floats(front, "duration").map { max(1, Int($0.rounded(.toNearestOrEven))) }
        let total = frames.reduce(0, +)
        guard let bucket = Self.buckets.first(where: { $0 >= total }) else { throw RenderError.tooLong(frames: total) }
        let phonemeOfFrame = frames.enumerated().flatMap { Array(repeating: $0.offset, count: $0.element) }

        // Per frame: pitch and energy, two values a frame
        let en = Self.gather(d, rows: n, columns: 640, at: phonemeOfFrame, transposing: true)
        lap("glue")
        let pitch = try predict(prosody, [
            "en": MLMultiArray(MLShapedArray<Float>(scalars: en, shape: [1, 640, total])),
            "style": MLMultiArray(MLShapedArray<Float>(scalars: style, shape: [1, 256])),
        ])
        lap("prosody")
        let f0 = Self.repeated(try floats(pitch, "F0"), to: 2 * bucket)
        let energy = Self.repeated(try floats(pitch, "N"), to: 2 * bucket)

        // The decoder's sine source, with its random numbers supplied here
        var phases = (0 ..< 9).map { _ in Float(random.uniform()) }
        phases[0] = 0
        let noise = random.gaussians(count: 9 * 600 * bucket)
        lap("noise")
        let sourced = try predict(source, [
            "f0": MLMultiArray(MLShapedArray<Float>(scalars: f0, shape: [1, 2 * bucket])),
            "phases": MLMultiArray(MLShapedArray<Float>(scalars: phases, shape: [1, 9])),
            "noise": MLMultiArray(MLShapedArray<Float>(scalars: noise, shape: [1, 9, 600 * bucket])),
        ])
        guard let harmonics = sourced.featureValue(for: "har")?.multiArrayValue else {
            throw NaturalVoicePhonemizer.Failure(errorDescription: "The voice's har output is missing.")
        }

        lap("source")
        // The body, padded to its size by repeating the sentence, as notebook 103 does
        let padded = (0 ..< bucket).map { phonemeOfFrame[$0 % total] }
        let asr = Self.gather(tEn, rows: 512, columns: n, at: padded, transposing: false)
        let model = try body(bucket)
        lap("glue+load")
        let audio = try predict(model, [
            "asr": MLMultiArray(MLShapedArray<Float>(scalars: asr, shape: [1, 512, bucket])),
            "f0": MLMultiArray(MLShapedArray<Float>(scalars: f0, shape: [1, 2 * bucket])),
            "n": MLMultiArray(MLShapedArray<Float>(scalars: energy, shape: [1, 2 * bucket])),
            "style": MLMultiArray(MLShapedArray<Float>(scalars: Array(style[..<128]), shape: [1, 128])),
            "har": harmonics,
        ])
        lap("body\(bucket)")
        let samples = Array(try floats(audio, "out").prefix(total * Self.frame))
        timing.debug("render: \(stages.joined(separator: ", "), privacy: .public)")
        return Self.trimmed(samples, words: Self.words(g2p.tokens, frames: frames))
    }

    /// The body for one size, loaded the first time it's needed: a function of the shared-weight `body.mlmodelc`, or
    /// `body<size>.mlmodelc` where there is one. The simulator's Core ML refuses `functionName` ("must be nil unless
    /// the model type is ML Program", for a model that is one), where macOS's loads the same file.
    private func body(_ bucket: Int) throws -> MLModel {
        if let model = bodies[bucket] { return model }
        let gpu = MLModelConfiguration()
        gpu.computeUnits = .cpuAndGPU
        var url: URL
        if let single = NaturalVoiceStore.file("body\(bucket).mlmodelc", in: folder) {
            url = single
        } else {
            url = folder.appending(path: "body.mlmodelc")
            gpu.functionName = "body\(bucket)"
        }
        let model = try MLModel(contentsOf: url, configuration: gpu)
        bodies[bucket] = model
        return model
    }

    private func predict(_ model: MLModel, _ inputs: [String: MLMultiArray]) throws -> MLFeatureProvider {
        try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
    }

    private func floats(_ output: MLFeatureProvider, _ name: String) throws -> [Float] {
        guard let array = output.featureValue(for: name)?.multiArrayValue else {
            throw NaturalVoicePhonemizer.Failure(errorDescription: "The voice's \(name) output is missing.")
        }
        if array.dataType == .float16 { return MLShapedArray<Float16>(array).scalars.map(Float.init) }
        return MLShapedArray<Float>(array).scalars
    }

    /// Repeats per-phoneme features once per frame. `x` is (rows, columns) row-major; the result is (channels, frames):
    /// with `transposing`, x's rows are phonemes and its columns channels (Tokens' d), else the other way round
    /// (Tokens' t_en).
    nonisolated static func gather(_ x: [Float], rows: Int, columns: Int, at phonemes: [Int], transposing: Bool) -> [Float] {
        let channels = transposing ? columns : rows
        var out = [Float](repeating: 0, count: channels * phonemes.count)
        x.withUnsafeBufferPointer { x in
            out.withUnsafeMutableBufferPointer { out in
                for c in 0 ..< channels {
                    let row = c * phonemes.count
                    for (f, p) in phonemes.enumerated() {
                        out[row + f] = transposing ? x[p * columns + c] : x[c * columns + p]
                    }
                }
            }
        }
        return out
    }

    /// Repeats `x` to length `n`: padding whose statistics look like the sentence's.
    nonisolated static func repeated(_ x: [Float], to n: Int) -> [Float] {
        (0 ..< n).map { x[$0 % x.count] }
    }

    /// Kokoro's `KPipeline.join_timestamps`: each token's span in the audio, from
    /// the frames each phoneme lasts, counting half-frames so a space can be split.
    nonisolated static func words(_ tokens: [NaturalVoicePhonemizer.Token], frames: [Int]) -> [Word] {
        guard !tokens.isEmpty, frames.count >= 3 else { return [] }
        let halfFrame = frame / 2
        var left = 2 * max(0, frames[0] - 3)
        var right = left
        var i = 1
        var words: [Word] = []
        for token in tokens {
            if i >= frames.count - 1 { break }
            if token.phonemes.isEmpty {
                if !token.whitespace.isEmpty {
                    i += 1
                    left = right + frames[i]
                    right = left + frames[i]
                    i += 1
                }
                continue
            }
            let j = i + token.phonemes.unicodeScalars.count
            if j >= frames.count { break }
            let start = left
            let spoken = frames[i ..< j].reduce(0, +)
            let space = token.whitespace.isEmpty ? 0 : frames[j]
            left = right + 2 * spoken + space
            right = left + space
            i = j + (token.whitespace.isEmpty ? 0 : 1)
            if token.text.contains(where: { $0.isLetter || $0.isNumber }) {
                words.append(Word(characters: token.start ..< token.end, samples: start * halfFrame ..< left * halfFrame))
            }
        }
        return words
    }

    /// Cuts the audio to the speech, keeping 0.1 s before the first word and 0.25 s after the last, as the
    /// notebooks' player does, and moves the words to match.
    nonisolated static func trimmed(_ samples: [Float], words: [Word]) -> Sentence {
        guard let first = words.first, let last = words.last else { return Sentence(samples: samples, words: []) }
        let from = max(0, first.samples.lowerBound - Int(0.1 * sampleRate))
        let to = min(samples.count, last.samples.upperBound + Int(0.25 * sampleRate))
        guard from < to else { return Sentence(samples: samples, words: words) }
        let moved = words.map {
            Word(characters: $0.characters,
                 samples: max(0, $0.samples.lowerBound - from) ..< max(0, min(to, $0.samples.upperBound) - from))
        }
        return Sentence(samples: Array(samples[from ..< to]), words: moved)
    }
}

/// A small, fast generator for the source's noise: millions of numbers a sentence.
nonisolated struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// In [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) * 0x1p-53 }

    /// Unit Gaussians, by Box-Muller: each pair of uniforms gives two. Accelerate does the logs, roots and sines.
    mutating func gaussians(count: Int) -> [Float] {
        let pairs = (count + 1) / 2
        var radius = [Float](repeating: 0, count: pairs)
        var angle = [Float](repeating: 0, count: pairs)
        radius.withUnsafeMutableBufferPointer { r in
            angle.withUnsafeMutableBufferPointer { a in
                for i in 0 ..< pairs {
                    r[i] = 1 - Float(next() >> 40) * 0x1p-24  // In (0, 1]: log(0) would be minus infinity
                    a[i] = Float(next() >> 40) * 0x1p-24 * 2 * .pi
                }
            }
        }
        radius = vForce.sqrt(vDSP.multiply(-2, vForce.log(radius)))
        var sines = [Float](repeating: 0, count: pairs)
        var cosines = [Float](repeating: 0, count: pairs)
        vForce.sincos(angle, sinResult: &sines, cosResult: &cosines)
        var out = [Float](repeating: 0, count: 2 * pairs)
        out.withUnsafeMutableBufferPointer { out in
            for i in 0 ..< pairs {
                out[2 * i] = radius[i] * cosines[i]
                out[2 * i + 1] = radius[i] * sines[i]
            }
        }
        return Array(out.prefix(count))
    }
}
