import SwiftUI

/// Show artwork with a placeholder that keeps the layout stable while loading —
/// lists must not jump around as images arrive.
///
/// The placeholder is a monogram: the show's initials on a colour drawn from
/// its title, so every show has a face of its own whether or not its feed
/// or site ever offered one, and a written show is not shown a waveform.
struct Artwork: View {
    let url: URL?
    var title: String = ""
    var size: CGFloat = 56

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Monogram(title: title, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
        // Purely decorative: the show's name is always beside it in text.
        .accessibilityHidden(true)
    }
}

/// A show's initials on a colour of its own.
struct Monogram: View {
    let title: String
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Color(hue: Monogram.hue(for: title), saturation: 0.42, brightness: 0.58)
            Text(Monogram.initials(of: title))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    /// The first letters of the title's first two words, "Simon Willison's
    /// Weblog" giving "SW". A leading article ("The", "A", "An") is skipped
    /// when something follows it, so "The Diff" is "D" rather than "TD" —
    /// but "The Rest Is History" keeps its "R" and "I".
    nonisolated static func initials(of title: String) -> String {
        var words = title
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "–" || $0 == "—" })
            .map { word in String(word.filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
        if words.count > 1, ["the", "a", "an"].contains(words[0].lowercased()) {
            words.removeFirst()
        }
        return words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined()
    }

    /// A stable hue for the title: the same show is always the same colour,
    /// and neighbouring shows in a list are unlikely to share one.
    nonisolated static func hue(for title: String) -> Double {
        // FNV-1a over the scalars. Swift's own hashing is seeded per process
        // and would recolour every show on each launch.
        var hash: UInt32 = 2_166_136_261
        for scalar in title.lowercased().unicodeScalars {
            hash ^= scalar.value
            hash = hash &* 16_777_619
        }
        return Double(hash % 360) / 360
    }
}
