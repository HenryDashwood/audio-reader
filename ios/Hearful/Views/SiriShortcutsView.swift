import AppIntents
import SwiftUI

struct SiriShortcutsView: View {
    var body: some View {
        List {
            Section {
                SiriTipView(intent: ContinueListeningIntent())
                ShortcutsLink()
                    .accessibilityLabel("Open Magpie actions in Shortcuts")
            } header: {
                Text("Start with your voice")
            } footer: {
                Text(
                    "Say Magpie in your request so Siri knows which app to use. Siri may ask for a show, item, or another detail."
                )
            }
            Section("Things to say to Siri") {
                Text("“Continue listening in Magpie.”")
                Text("“Ask Magpie.”")
                Text("“Run a request in Magpie.”")
                Text("“Change the speed in Magpie.”")
                Text("“Set a sleep timer in Magpie.”")
                Text("“What am I listening to in Magpie?”")
            }
            Section {
                Text(
                    "Use Run a Magpie Request with text or Dictate Text to pass a request straight to Magpie. Your words carry across if the app needs to open."
                )
                Text(
                    "For a listening routine, combine Find Listening Items, Play a Listening Item, Set Playback Speed, and Set Sleep Timer."
                )
                Text(
                    "Find Listening Items returns Latest when you leave the search and show empty. A duration filter includes only items with a known length."
                )
            } header: {
                Text("Make your own shortcuts")
            }
            Section {
                Text(
                    "For the Action button, choose Shortcuts in iPhone Settings, then choose Ask Magpie or Continue Listening."
                )
                Text(
                    "In Control Center, add Magpie’s Ask Magpie or Continue Listening control. You can also choose these controls when customizing your Lock Screen."
                )
                Text(
                    "In Settings → Accessibility → Touch → Back Tap, you can assign a shortcut you have saved."
                )
            } header: {
                Text("Other ways in")
            }
        }
        .navigationTitle("Siri and Shortcuts")
        .toolbarTitleDisplayMode(.inline)
    }
}
