import SwiftUI

/// Show artwork with a placeholder that keeps the layout stable while loading —
/// lists must not jump around as images arrive.
struct Artwork: View {
    let url: URL?
    var size: CGFloat = 56

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
        // Purely decorative: the show's name is always beside it in text.
        .accessibilityHidden(true)
    }
}
