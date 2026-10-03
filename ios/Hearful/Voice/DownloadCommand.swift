import Foundation

/// "Download this", said about whatever is playing.
///
/// Matched on the phone like the transport controls, and like them only when
/// the whole utterance is the command: "download the new episode of In Our
/// Time" names something else, and is left for the model.
enum DownloadCommand: Equatable {
    case download
    case remove

    /// An answer to "Shall I download it anyway?"
    enum Reply: Equatable {
        case yes
        /// Only meaningful when the question offered to wait for Wi-Fi.
        case waitForWiFi
        case no
    }

    static func match(_ transcript: String) -> DownloadCommand? {
        let phrase = normalise(transcript)
        if downloadPhrases.contains(phrase) { return .download }
        if removePhrases.contains(phrase) { return .remove }
        return nil
    }

    static func reply(_ transcript: String) -> Reply? {
        let phrase = normalise(transcript)
        if yesPhrases.contains(phrase) { return .yes }
        if waitPhrases.contains(phrase) { return .waitForWiFi }
        if noPhrases.contains(phrase) { return .no }
        return nil
    }

    private static let things = ["this", "this episode", "this one", "it", "this podcast", "the episode", "that", "that episode"]

    private static let downloadPhrases: Set<String> = {
        var phrases: Set<String> = ["download", "download for offline", "save for offline"]
        for thing in things {
            phrases.insert("download \(thing)")
            phrases.insert("download \(thing) for offline")
            phrases.insert("save \(thing) for offline")
            phrases.insert("keep \(thing) for offline")
            phrases.insert("make \(thing) available offline")
        }
        return phrases
    }()

    private static let removePhrases: Set<String> = {
        var phrases: Set<String> = [
            "remove download", "delete download", "remove the download", "delete the download",
            "remove this download", "delete this download", "remove that download", "delete that download",
        ]
        for thing in things {
            phrases.insert("remove \(thing) from downloads")
            phrases.insert("delete \(thing) from downloads")
            phrases.insert("remove the download of \(thing)")
            phrases.insert("delete the download of \(thing)")
        }
        return phrases
    }()

    private static let yesPhrases: Set<String> = [
        "yes", "yeah", "yep", "yes please", "sure", "go ahead", "do it", "download it", "download it anyway",
        "download anyway", "download now", "download it now", "now", "ok", "okay", "use mobile data",
        "yes download it", "yes use mobile data", "that's fine", "thats fine", "fine",
    ]

    private static let waitPhrases: Set<String> = [
        "wait", "wait for wifi", "wait for wi fi", "wait until wifi", "wait until wi fi",
        "wait until i'm on wifi", "wait until i'm on wi fi", "later", "on wifi", "on wi fi",
        "when i'm on wifi", "when i'm on wi fi", "download it later", "download later",
    ]

    private static let noPhrases: Set<String> = [
        "no", "nope", "no thanks", "no thank", "cancel", "don't", "dont", "don't download it",
        "never mind", "nevermind", "forget it", "stop",
    ]

    private static func normalise(_ transcript: String) -> String {
        let lowered = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "-", with: " ")
        let letters = lowered.map { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "'" ? $0 : " " }
        var words = String(letters).split(separator: " ").map(String.init)
        words.removeAll { filler.contains($0) }
        return words.joined(separator: " ")
    }

    private static let filler: Set<String> = ["please", "can", "could", "you", "hey", "just", "my", "me"]
}
