import Foundation

/// One of Kokoro's voices.
///
/// A voice is not a model. The 82M-parameter network is a single file; each
/// voice is a style tensor of about half a megabyte inside `voices.npz`. So
/// offering another voice costs a row in the picker rather than another
/// download — the opposite of the hosted services, where every voice we offer
/// multiplies what has to be rendered and stored.
///
/// The catalogue below is a shortlist, not the full 54: the voices with enough
/// training data behind them to sound like a person reading, British first
/// because the app defaults to en-GB. It is filtered at load time against what
/// the file on disk actually contains, so a name that turns out to be wrong
/// disappears from the picker instead of failing when she presses play.
nonisolated struct KokoroVoice: Equatable, Identifiable, Sendable {
    /// The key inside `voices.npz`, e.g. `bf_emma`.
    let name: String
    /// What the picker shows.
    let displayName: String

    var id: String { name }

    /// How the choice is stored. Namespaced so it can never be mistaken for an
    /// `AVSpeechSynthesisVoice` identifier, which is what the same picker holds
    /// for the system voices.
    var identifier: String { Self.identifierPrefix + name }

    /// Kokoro's own convention: an `a` prefix is American, `b` British. It
    /// selects the pronunciation rules, not just the accent, so it has to be
    /// passed through to the engine rather than inferred from the text.
    var isBritish: Bool { name.hasPrefix("b") }

    static let identifierPrefix = "kokoro:"

    static func name(fromIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return String(identifier.dropFirst(identifierPrefix.count))
    }

    static func named(_ name: String) -> KokoroVoice? {
        catalogue.first { $0.name == name }
    }

    /// The voices worth offering, best-supported first within each accent.
    static let catalogue: [KokoroVoice] = [
        KokoroVoice(name: "bf_emma", displayName: "Emma (UK)"),
        KokoroVoice(name: "bf_isabella", displayName: "Isabella (UK)"),
        KokoroVoice(name: "bf_alice", displayName: "Alice (UK)"),
        KokoroVoice(name: "bf_lily", displayName: "Lily (UK)"),
        KokoroVoice(name: "bm_george", displayName: "George (UK)"),
        KokoroVoice(name: "bm_lewis", displayName: "Lewis (UK)"),
        KokoroVoice(name: "bm_daniel", displayName: "Daniel (UK)"),
        KokoroVoice(name: "bm_fable", displayName: "Fable (UK)"),
        KokoroVoice(name: "af_heart", displayName: "Heart (US)"),
        KokoroVoice(name: "af_bella", displayName: "Bella (US)"),
        KokoroVoice(name: "af_nicole", displayName: "Nicole (US)"),
        KokoroVoice(name: "am_michael", displayName: "Michael (US)"),
        KokoroVoice(name: "am_fenrir", displayName: "Fenrir (US)"),
    ]
}
