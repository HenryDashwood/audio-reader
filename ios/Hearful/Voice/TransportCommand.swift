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

    /// Returns a command only when the whole utterance is that command.
    ///
    /// Matching on substrings would be a disaster: "play the one about Rome"
    /// contains "play", and "go back to the Rome episode" contains "go back".
    /// Those are requests for the model, not transport nudges, so anything
    /// with content beyond a bare instruction is deliberately left alone.
    static func match(_ transcript: String) -> TransportCommand? {
        let phrase = normalise(transcript)
        guard !phrase.isEmpty else { return nil }
        return phrases[phrase]
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
    ]

    /// Strips politeness and filler so "can you pause please" still counts.
    private static func normalise(_ transcript: String) -> String {
        let lowered = transcript.lowercased()
        let letters = lowered.map { $0.isLetter || $0.isWhitespace ? $0 : " " }
        var words = String(letters).split(separator: " ").map(String.init)
        words.removeAll { filler.contains($0) }
        return words.joined(separator: " ")
    }

    private static let filler: Set<String> = [
        "please", "can", "could", "you", "hey", "ok", "okay", "now", "just", "it", "a", "bit",
    ]
}
