import Foundation

/// One line of a spoken exchange: something she said, or something the app
/// said back to her.
///
/// Encodable only. Turns travel outwards with every request and never come
/// back — the phone is the one holding the exchange, and the backend answers
/// from what it was sent.
nonisolated struct ConversationTurn: Encodable, Equatable {
    nonisolated enum Speaker: String, Encodable {
        case her
        case app
    }

    let speaker: Speaker
    let text: String
}

/// What has been said so far, and the whole of what makes a request more than
/// one sentence long.
///
/// "The one about Agincourt" is not a command. It is the second half of one,
/// and until this existed the first half was thrown away the moment the app
/// finished speaking: she would be asked which episode she meant, answer, and
/// have her answer read as though she had walked up and said it out of
/// nowhere. Every clarification the app asked for was a question it could not
/// use the answer to.
///
/// Held here rather than on the server: an exchange is a handful of short
/// sentences that matter for the next half-minute, so keeping it on the phone
/// costs a few hundred tokens per request and saves a session table, an expiry
/// sweep, and any question of which device is mid-sentence. It is also the
/// list she can see — the transcript in the voice sheet is these turns, so
/// what is on screen is exactly what the model is being told.
struct Conversation: Equatable {
    /// How many turns travel with a request. Four questions and their answers,
    /// which is more than any real request needs; past that the history
    /// describes a subject she has moved on from. The backend trims to the
    /// same number, and neither side depends on the other having done it.
    static let sent = 8

    /// How long a gap ends the subject.
    ///
    /// A tap two minutes later is a new request, not the next line of an
    /// exchange she has stopped thinking about — and reading it against those
    /// old lines is worse than having no history at all, because it is
    /// confidently wrong rather than merely ignorant.
    static let forgetAfter = Duration.seconds(120)

    /// Oldest first. Everything said since the subject started, which is what
    /// the screen shows; requests carry only the most recent `sent` of them.
    private(set) var turns: [ConversationTurn] = []

    /// When the last line landed, for the staleness check. Nil while empty.
    private var lastSpoke: ContinuousClock.Instant?

    var isEmpty: Bool { turns.isEmpty }

    /// The turns that travel with the next request, oldest first.
    var payload: [ConversationTurn] { Array(turns.suffix(Self.sent)) }

    /// True when the app's own last line was the most recent thing said, which
    /// is the shape of an exchange waiting on her.
    var isAwaitingHer: Bool { turns.last?.speaker == .app }

    mutating func sheSaid(_ text: String, at instant: ContinuousClock.Instant = .now) {
        add(ConversationTurn(speaker: .her, text: text), at: instant)
    }

    mutating func appSaid(_ text: String, at instant: ContinuousClock.Instant = .now) {
        add(ConversationTurn(speaker: .app, text: text), at: instant)
    }

    mutating func clear() {
        turns = []
        lastSpoke = nil
    }

    /// Drops the whole exchange if nothing has been said for a while.
    ///
    /// All of it, rather than the oldest lines: half an exchange is not
    /// context, it is a question with its answer missing or an answer with
    /// nothing to answer. Called when she starts speaking rather than on a
    /// timer, so the transcript stays on screen for as long as she leaves the
    /// sheet open and only clears when it would otherwise be used.
    mutating func forgetIfStale(now: ContinuousClock.Instant = .now) {
        guard let lastSpoke, now - lastSpoke > Self.forgetAfter else { return }
        clear()
    }

    private mutating func add(_ turn: ConversationTurn, at instant: ContinuousClock.Instant) {
        // Blank lines would be a turn she can see on screen and cannot read,
        // and a line in the prompt with nothing in the quotes.
        guard !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        turns.append(turn)
        lastSpoke = instant
    }
}
