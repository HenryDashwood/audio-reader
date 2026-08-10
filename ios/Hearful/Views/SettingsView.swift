import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthController
    @State private var voiceID: String = SpeechVoice.current?.identifier ?? ""
    @State private var previewSpeaker = Speaker()
    private let voices = SpeechVoice.englishVoices()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Reading voice", selection: $voiceID) {
                        ForEach(voices, id: \.identifier) { voice in
                            Text(label(for: voice)).tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Voice")
                } footer: {
                    Text(
                        "Used for articles and spoken replies. Better voices — "
                            + "including Alex — can be downloaded free in "
                            + "Settings → Accessibility → Spoken Content → Voices, "
                            + "and appear here once installed."
                    )
                }

                Section("Account") {
                    Button("Sign Out", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                    .accessibilityHint("Returns to the sign in screen")
                }
            }
            .navigationTitle("Settings")
            .onChange(of: voiceID) { _, identifier in
                SpeechVoice.select(identifier: identifier)
                // Hearing it is the only way to choose it.
                Task { await previewSpeaker.speak("This voice will read your articles.") }
            }
        }
    }

    private func label(for voice: AVSpeechSynthesisVoice) -> String {
        var parts = [voice.name]
        if let region = voice.language.split(separator: "-").last {
            parts.append(region == "GB" ? "UK" : String(region))
        }
        switch voice.quality {
        case .premium: parts.append("Premium")
        case .enhanced: parts.append("Enhanced")
        default: parts.append(SpeechVoice.isNatural(voice) ? "Standard" : "Robotic")
        }
        return parts.joined(separator: " · ")
    }
}
