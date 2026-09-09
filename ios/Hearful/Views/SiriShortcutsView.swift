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
                Text("“Talk to Magpie.”")
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
                Text("Tap the back of your iPhone three times to open Magpie, ready to listen. Set this up once on your iPhone:")
                Text("1. Open Shortcuts and create a new shortcut. Add Magpie’s Ask Magpie action, then name the shortcut Ask Magpie.")
                ShortcutsLink()
                    .accessibilityLabel("Open Magpie actions in Shortcuts")
                Text("2. Open iPhone Settings → Accessibility → Touch → Back Tap → Triple Tap.")
                Text("3. Under Shortcuts, select the Ask Magpie shortcut you saved.")
                Text("4. Tap the back of your iPhone three times. Unlock it if asked, then wait for Magpie’s listening sound before speaking.")
            } header: {
                Text("Launch with Triple Back Tap")
            } footer: {
                Text("Magpie cannot assign Back Tap for you. Your Action button can keep its current function.")
            }
            Section("During a conversation") {
                Text("Wait for the listening sound after each reply, then speak again. Say “That’s all” to close the conversation, or stay quiet to end listening.")
                Text("With VoiceOver, double-tap with two fingers anywhere in the conversation to finish speaking, interrupt Magpie, or start listening again.")
                Text("Change Keep listening after replies and the waiting time in Magpie Settings → Conversation.")
            }
            Section {
                Text(
                    "For the Action button, choose Shortcuts in iPhone Settings, then choose Ask Magpie or Continue Listening."
                )
                Text(
                    "In Control Center, add Magpie’s Ask Magpie or Continue Listening control. You can also choose these controls when customizing your Lock Screen."
                )
            } header: {
                Text("Other ways in")
            }
        }
        .navigationTitle("Siri and Shortcuts")
        .toolbarTitleDisplayMode(.inline)
    }
}
