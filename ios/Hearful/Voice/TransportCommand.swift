import Foundation

/// Controls that must never wait on the network.
///
/// "Pause" is the most-used thing anyone says to an audio app, and sending it
/// to a server to be interpreted would put seconds between her saying it and
/// the sound stopping. These are matched on the phone, work with no signal,
/// and cost nothing.
enum TransportCommand: Equatable {
    case pause
    case resume
    case skipForward
    case skipBack
    case faster
    case slower
    case normalSpeed
    case seek(TimeInterval)
    case speed(Float)

    /// Returns a command only when the whole utterance is that command.
    ///
    /// Matching on substrings would be a disaster: "play the one about Rome"
    /// contains "play", and "go back to the Rome episode" contains "go back".
    /// Those are requests for the model, not transport nudges, so anything
    /// with content beyond a bare instruction is deliberately left alone.
    static func match(_ transcript: String) -> TransportCommand? {
        let phrase = normalise(transcript)
        guard !phrase.isEmpty else { return nil }
        if let command = parameterized(phrase) { return command }
        return phrases[phrase]
    }

    private static func parameterized(_ phrase: String) -> TransportCommand? {
        for (prefix, direction) in [("go back ", -1.0), ("rewind ", -1.0), ("skip back ", -1.0),
                                    ("skip forward ", 1.0), ("skip ahead ", 1.0), ("jump forward ", 1.0)] {
            guard phrase.hasPrefix(prefix) else { continue }
            let rest = String(phrase.dropFirst(prefix.count))
            for (unit, multiplier) in [("seconds", 1.0), ("second", 1.0), ("minutes", 60.0), ("minute", 60.0), ("hours", 3600.0), ("hour", 3600.0)] {
                guard rest.hasSuffix(" " + unit), let value = spokenNumber(String(rest.dropLast(unit.count + 1))),
                      value > 0, value * multiplier <= 7200 else { continue }
                return .seek(value * multiplier * direction)
            }
        }
        for prefix in ["play at ", "set speed to ", "speed ", "playback speed "] where phrase.hasPrefix(prefix) {
            var rest = String(phrase.dropFirst(prefix.count))
            for suffix in [" times normal speed", " times speed", " times", " speed", "x"] where rest.hasSuffix(suffix) {
                rest = String(rest.dropLast(suffix.count))
                break
            }
            if let value = spokenNumber(rest), (0.5...3).contains(value) { return .speed(Float(value)) }
        }
        return nil
    }

    private static func spokenNumber(_ text: String) -> Double? {
        if let value = Double(text), value.isFinite { return value }
        let fixed: [String: Double] = ["half": 0.5, "double": 2, "one and half": 1.5,
            "one and quarter": 1.25, "two and half": 2.5, "one point five": 1.5,
            "one point two five": 1.25, "two point five": 2.5]
        if let value = fixed[text] { return value }
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                     "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        if let index = units.firstIndex(of: text) { return Double(index) }
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first, let ten = tens[first] else { return nil }
        if words.count == 1 { return Double(ten) }
        if words.count == 2, let unit = units.firstIndex(of: words[1]), unit < 10 { return Double(ten + unit) }
        return nil
    }

    private static let phrases: [String: TransportCommand] = [
        "pause": .pause, "stop": .pause, "be quiet": .pause, "quiet": .pause,
        "shush": .pause, "hold on": .pause, "wait": .pause, "silence": .pause,

        "resume": .resume, "continue": .resume, "carry on": .resume,
        "keep going": .resume, "go on": .resume, "unpause": .resume,
        "play": .resume, "start again": .resume, "start": .resume,

        "skip": .skipForward, "skip forward": .skipForward, "skip ahead": .skipForward,
        "jump forward": .skipForward, "forward": .skipForward, "fast forward": .skipForward,

        "go back": .skipBack, "back": .skipBack, "rewind": .skipBack,
        "say that again": .skipBack, "repeat that": .skipBack, "repeat": .skipBack,
        "what was that": .skipBack, "go back a bit": .skipBack,

        // Relative speed nudges resolve locally, alongside the parameterized
        // absolute speeds handled above.
        // "speed it up" also lands here: normalise strips "it".
        "faster": .faster, "speed up": .faster, "quicker": .faster,
        "go faster": .faster, "too slow": .faster,

        "slower": .slower, "slow down": .slower, "not so fast": .slower,
        "too fast": .slower,

        "normal speed": .normalSpeed, "regular speed": .normalSpeed,
        "usual speed": .normalSpeed, "ordinary speed": .normalSpeed,
    ]

    /// Strips politeness and filler so "can you pause please" still counts.
    private static func normalise(_ transcript: String) -> String {
        let lowered = transcript.lowercased().replacingOccurrences(
            of: #"(?<![0-9])\.|\.(?![0-9])"#, with: " ", options: .regularExpression)
        let letters = lowered.map { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "." ? $0 : " " }
        var words = String(letters).split(separator: " ").map(String.init)
        words.removeAll { filler.contains($0) }
        return words.joined(separator: " ")
    }

    private static let filler: Set<String> = [
        "please", "can", "could", "you", "hey", "ok", "okay", "now", "just", "it", "a", "bit",
    ]
}
