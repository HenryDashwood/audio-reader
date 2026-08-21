import Foundation

/// Small, explicit fixes for text that the Swift Misaki port phonemizes
/// differently from ordinary spoken English.
nonisolated enum KokoroTextNormalization {
    /// Misaki pronounces lowercase "a" as reduced /ɐ/ only when Apple's tagger
    /// calls it a determiner. On device that tag is unreliable, and Misaki's
    /// fallback is the deliberately stressed letter name /ˈA/ ("AY").
    ///
    /// A lowercase `a` followed by another word is overwhelmingly the
    /// indefinite article in article prose. Misaki's supported inline phoneme
    /// syntax keeps the visible token while making that pronunciation
    /// unambiguous. Uppercase `A`, words containing `a`, `a.m.`, and a
    /// sentence-final letter remain untouched.
    static func forSynthesis(_ text: String) -> String {
        guard text.contains("a") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "a",
                isWordBoundary(before: index, in: text),
                beginsFollowingWord(at: next, in: text)
            {
                result += "[a](/ɐ/)"
            } else {
                result.append(text[index])
            }
            index = next
        }
        return result
    }

    private static func isWordBoundary(before index: String.Index, in text: String) -> Bool {
        guard index != text.startIndex else { return true }
        let character = text[text.index(before: index)]
        return !character.isLetter && !character.isNumber
            && character != "_" && character != "'" && character != "’"
    }

    /// An article needs a following noun phrase. Requiring a following word,
    /// separated by whitespace (with optional opening quotes/brackets), avoids
    /// rewriting abbreviations such as `a.m.` and mentions of the letter `a`.
    private static func beginsFollowingWord(at start: String.Index, in text: String) -> Bool {
        let opening = Set<Character>("\"'“‘([{<")
        var index = start
        var sawWhitespace = false
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                sawWhitespace = true
            } else if sawWhitespace, opening.contains(character) {
                // Keep looking through opening punctuation: `a “Cyclops”`.
            } else {
                return sawWhitespace && (character.isLetter || character.isNumber)
            }
            index = text.index(after: index)
        }
        return false
    }
}
