import Foundation
import NaturalLanguage

/// An article's text prepared for speech: ordered chunks laid out on an
/// estimated timeline, so the scrubber, the skip buttons, saved positions and
/// the lock screen all work in seconds even though nothing is streamed.
///
/// The timeline is computed from word count at a fixed reading speed, always
/// at 1× — like media time, it must not move when the playback rate changes,
/// or positions saved at 2× would resume in the wrong place.
nonisolated struct ArticleScript: Equatable {
    struct Chunk: Equatable {
        let text: String
        /// Estimated seconds from the start of the article to this chunk.
        let start: TimeInterval
        let duration: TimeInterval
        var end: TimeInterval { start + duration }
    }

    let chunks: [Chunk]
    var duration: TimeInterval { chunks.last?.end ?? 0 }
    var isEmpty: Bool { chunks.isEmpty }

    /// Comfortable spoken-word pace; only relative accuracy matters, since
    /// the same constant maps seconds back to chunks on resume.
    static let wordsPerMinute = 170.0
    /// Long paragraphs are split so pause/seek stay responsive: a synthesiser
    /// can only stop cleanly between utterances or at word boundaries.
    static let chunkCharacterLimit = 320

    init(text: String) {
        var built: [Chunk] = []
        var clock: TimeInterval = 0
        for paragraph in text.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for piece in Self.pieces(of: trimmed) {
                let words = piece.split(whereSeparator: \.isWhitespace).count
                // Never zero: a zero-length chunk could never be seeked past.
                let seconds = max(Double(words) / Self.wordsPerMinute * 60, 0.5)
                built.append(Chunk(text: piece, start: clock, duration: seconds))
                clock += seconds
            }
        }
        chunks = built
    }

    /// The chunk the given (estimated) time falls in, clamped to the ends.
    func index(at time: TimeInterval) -> Int? {
        guard !chunks.isEmpty else { return nil }
        if let found = chunks.firstIndex(where: { time < $0.end }) {
            return found
        }
        return chunks.count - 1
    }

    /// A paragraph as speakable utterances: whole if short, else sentences
    /// packed greedily up to the limit so pauses stay natural.
    static func pieces(of paragraph: String, limit: Int = chunkCharacterLimit) -> [String] {
        guard paragraph.count > limit else { return [paragraph] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            let sentence = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        guard !sentences.isEmpty else { return [paragraph] }

        var pieces: [String] = []
        var current = ""
        for sentence in sentences {
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count + 1 <= limit {
                current += " " + sentence
            } else {
                pieces.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
