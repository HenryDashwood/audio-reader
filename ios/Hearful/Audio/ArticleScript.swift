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
        /// Where this utterance came from in the complete article text. Like
        /// AVSpeechSynthesizer's ranges, this uses UTF-16 offsets.
        let textRange: NSRange
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
        let source = text as NSString
        var built: [Chunk] = []
        var clock: TimeInterval = 0
        var paragraphSearchStart = 0
        for paragraph in text.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let remaining = NSRange(
                location: paragraphSearchStart,
                length: max(source.length - paragraphSearchStart, 0))
            let paragraphRange = source.range(of: trimmed, options: [], range: remaining)
            guard paragraphRange.location != NSNotFound else { continue }
            let paragraphText = trimmed as NSString
            var pieceSearchStart = 0
            for piece in Self.pieces(of: trimmed) {
                let pieceRemaining = NSRange(
                    location: pieceSearchStart,
                    length: max(paragraphText.length - pieceSearchStart, 0))
                let localRange = paragraphText.range(
                    of: piece, options: [], range: pieceRemaining)
                guard localRange.location != NSNotFound else { continue }
                let words = piece.split(whereSeparator: \.isWhitespace).count
                // Never zero: a zero-length chunk could never be seeked past.
                let seconds = max(Double(words) / Self.wordsPerMinute * 60, 0.5)
                built.append(
                    Chunk(
                        text: piece,
                        textRange: NSRange(
                            location: paragraphRange.location + localRange.location,
                            length: localRange.length),
                        start: clock,
                        duration: seconds))
                clock += seconds
                pieceSearchStart = NSMaxRange(localRange)
            }
            paragraphSearchStart = NSMaxRange(paragraphRange)
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
        let sentences = sentences(of: paragraph)
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

    /// Sentence boundaries are the natural unit for an offline voice: the
    /// model sees enough context to plan emphasis and pauses, while the first
    /// sentence can still start before the rest of a paragraph is rendered.
    static func sentences(of text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences.isEmpty && !text.isEmpty ? [text] : sentences
    }
}
