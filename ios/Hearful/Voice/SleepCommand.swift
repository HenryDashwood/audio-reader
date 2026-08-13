import Foundation

/// "Stop in twenty minutes", said out loud.
///
/// Matched on the phone rather than by the model for the same reason as the
/// transport controls — it should work with no signal, at night, instantly —
/// but with its own matcher rather than TransportCommand's, because that one
/// strips digits and requires the whole utterance to be a single fixed
/// phrase. A duration is neither.
enum SleepCommand: Equatable {
    case after(minutes: Int)
    case cancel

    /// How long a bare "set a sleep timer" means. Announced back to her, so a
    /// wrong guess costs one correction rather than a silent surprise.
    static let defaultMinutes = 30

    /// Deliberately hard to trigger by accident.
    ///
    /// The trap here is that "sleep" is also a subject people make podcasts
    /// about: "play the one about sleep" must reach the model, not silently
    /// set a timer and leave her in silence wondering why nothing played. So a
    /// bare mention of sleeping is never enough. Either the word "timer" is
    /// present, or there is an actual duration attached to a word about
    /// stopping — and anything that names a thing to play is left alone
    /// outright.
    static func match(_ transcript: String) -> SleepCommand? {
        let words = normalise(transcript)
        guard !words.contains(where: contentVerbs.contains) else { return nil }

        let mentionsTimer = words.contains("timer")
        let mentionsStopping =
            mentionsTimer || words.contains(where: sleepWords.contains)
            || words.contains("stop") || words.contains("off")

        // A duration settles it: "turn it off in twenty minutes" is a timer
        // being set, not one being cancelled, however it is phrased.
        if mentionsStopping, let minutes = duration(in: words) {
            return .after(minutes: minutes)
        }
        // Without a duration, only an explicit "timer" is unambiguous enough.
        guard mentionsTimer else { return nil }
        if words.contains(where: cancelWords.contains) {
            return .cancel
        }
        return .after(minutes: defaultMinutes)
    }

    // MARK: - Durations

    private static func duration(in words: [String]) -> Int? {
        if let minutes = fixedPhrase(in: words) { return minutes }
        guard let value = number(in: words) else { return nil }
        let hours = words.contains("hour") || words.contains("hours")
        let minutes = hours ? value * 60 : value
        // Anything longer than a night, or shorter than it takes to say the
        // sentence, is a mishearing rather than a request.
        return (1...720).contains(minutes) ? minutes : nil
    }

    private static func fixedPhrase(in words: [String]) -> Int? {
        let phrase = words.joined(separator: " ")
        for (text, minutes) in [
            ("half an hour", 30), ("half hour", 30),
            ("an hour and a half", 90), ("hour and a half", 90),
            ("an hour", 60), ("one hour", 60),
        ] where phrase.contains(text) {
            return minutes
        }
        return nil
    }

    /// The first number in the sentence, written either way. Spoken numbers
    /// arrive as words about as often as digits, depending on the recogniser.
    private static func number(in words: [String]) -> Int? {
        var tens: Int?
        for word in words {
            if let digits = Int(word) { return digits }
            if let units = units[word] {
                // "twenty five" — the tens came first.
                return (tens ?? 0) + units
            }
            if let value = multiplesOfTen[word] {
                tens = value
            }
        }
        return tens
    }

    private static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]

    private static let multiplesOfTen: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    // MARK: - Vocabulary

    private static let sleepWords: Set<String> = ["sleep", "sleeping", "asleep", "bed"]
    private static let cancelWords: Set<String> = [
        "cancel", "clear", "remove", "forget", "off", "no", "stop",
    ]

    /// Naming something to play, follow or drop makes this the model's
    /// business, whatever else the sentence happens to contain. "playing" is
    /// deliberately absent: "stop playing in twenty minutes" is a timer.
    private static let contentVerbs: Set<String> = [
        "play", "subscribe", "unsubscribe", "listen", "read", "find", "search",
    ]

    /// Keeps digits, unlike TransportCommand's: the number is the point.
    private static func normalise(_ transcript: String) -> [String] {
        let kept = transcript.lowercased().map {
            $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " "
        }
        return String(kept).split(separator: " ").map(String.init)
            .filter { !filler.contains($0) }
    }

    private static let filler: Set<String> = [
        "please", "can", "could", "you", "hey", "ok", "okay", "just", "the", "for", "in",
        "after", "set", "put", "me", "my", "i", "want", "to", "go", "at", "on",
    ]
}
