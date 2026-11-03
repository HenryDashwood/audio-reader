import Foundation
import MagpieG2P

/// Text to the phonemes Kokoro reads, through native/g2p: misaki in Rust, with
/// the lexicon and model the voice download adds for words misaki can't say,
/// and abbreviations written out first.
///
/// @unchecked Sendable because the Rust side takes `&self` for phonemizing and
/// guards its one cache with a mutex, so the handle is safe to share.
nonisolated final class NaturalVoicePhonemizer: @unchecked Sendable {
    /// One token as misaki splits the text. `start` and `end` are UTF-16
    /// offsets into the text given, the units NSRange counts; a written-out
    /// abbreviation ("Street" for "St.") covers the abbreviation.
    struct Token: Decodable, Sendable, Equatable {
        let text: String
        let phonemes: String
        let whitespace: String
        let start: Int
        let end: Int
    }

    struct Phonemes: Decodable, Sendable {
        let phonemes: String
        let tokens: [Token]
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private let handle: OpaquePointer

    /// Loads one accent's lexicons, tagger and model from the voice's folder.
    init(folder: URL, british: Bool) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let handle = magpie_g2p_open(folder.path, british, &error) else {
            defer { magpie_g2p_free_string(error) }
            throw Failure(errorDescription: error.map { String(cString: $0) } ?? "The voice's text files could not be read.")
        }
        self.handle = handle
    }

    deinit {
        magpie_g2p_close(handle)
    }

    func phonemize(_ text: String) throws -> Phonemes {
        guard let json = magpie_g2p_phonemize(handle, text) else {
            throw Failure(errorDescription: "The voice could not read this text.")
        }
        defer { magpie_g2p_free_string(json) }
        let data = Data(bytes: json, count: strlen(json))
        if let failure = try? JSONDecoder().decode([String: String].self, from: data), let message = failure["error"] {
            throw Failure(errorDescription: message)
        }
        return try JSONDecoder().decode(Phonemes.self, from: data)
    }
}
