import SwiftUI

/// Opens a page's search field.
///
/// Both searchable pages let the field hide until a pull-down, which keeps the
/// screen quiet but leaves nothing to find: a field scrolled off the top is
/// reachable only by swiping backwards past the first row and hoping the list
/// scrolls, which is not a gesture anyone should have to know about. This is
/// the same field, as an ordinary button sitting in the navigation bar where
/// VoiceOver reaches it in one swipe from the title.
struct SearchToolbarButton: View {
    /// What this field searches — "Search this show", "Search podcasts".
    /// Spoken in place of the icon, so it says which search this opens on a
    /// screen that may have more than one control in the bar.
    let label: String
    @FocusState.Binding var focused: Bool

    var body: some View {
        Button {
            focused = true
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel(label)
        .accessibilityHint("Opens the search field")
    }
}
