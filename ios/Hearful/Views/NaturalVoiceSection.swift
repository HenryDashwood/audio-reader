import AVFoundation
import SwiftUI

/// Settings' natural voice: download it, choose who reads articles, remove it.
struct NaturalVoiceSection: View {
    @ObservedObject private var download = NaturalVoiceDownload.shared
    /// A speaker's name, or "" for Apple's voice.
    @State private var selection = NaturalVoiceStore.selectedID() ?? ""
    @State private var preview: NaturalVoiceSynthesizer?
    @State private var confirmingRemove = false

    var body: some View {
        Section {
            switch download.state {
            case .checking:
                ProgressView()
            case .notInstalled:
                Button("Download Natural Voice (\(NaturalVoiceDownload.approximateSize))") {
                    Task { await download.download() }
                }
            case .waiting:
                ProgressView("Waiting to download…")
                cancelButton
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading the natural voice")
                } currentValueLabel: {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                }
                cancelButton
            case .paused(let fraction):
                ProgressView(value: fraction) {
                    Text("Download paused")
                } currentValueLabel: {
                    Text("It carries on when your iPhone is back online.")
                }
                cancelButton
            case .cancelling:
                ProgressView("Cancelling…")
            case .installed(let voices):
                Picker("Read Articles With", selection: Binding(get: { selection }, set: choose)) {
                    Text("Apple Voice").tag("")
                    ForEach(voices) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
                .pickerStyle(.navigationLink)
                Button("Remove Natural Voice", role: .destructive) { confirmingRemove = true }
            case .failed(let message):
                Text(message)
                Button("Try Again") { Task { await download.download() } }
            }
        } header: {
            Text("Natural Voice")
        } footer: {
            Text(
                "A more natural voice for reading articles. It runs on this iPhone, so it works offline once "
                    + "downloaded. Magpie’s spoken replies keep the Apple voice."
            )
        }
        .task { await download.refresh() }
        .onChange(of: download.state) { old, new in
            if case .installed = new, old != new, old != .checking {
                AccessibilityNotification.Announcement("The natural voice has downloaded.").post()
            }
            if case .notInstalled = new { selection = "" }
        }
        .confirmationDialog(
            "Remove the natural voice?", isPresented: $confirmingRemove, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                selection = ""
                preview = nil
                Task { await download.remove() }
            }
        } message: {
            Text("Articles will be read with the Apple voice. You can download it again at any time.")
        }
    }

    private var cancelButton: some View {
        Button("Cancel Download", role: .cancel) { Task { await download.cancel() } }
    }

    /// Saves the choice, and lets her hear it: the first sentence takes a moment while the voice loads.
    private func choose(_ id: String) {
        selection = id
        guard case .installed(let voices) = download.state else { return }
        let voice = voices.first { $0.id == id }
        NaturalVoiceStore.select(voice)
        preview?.stopSpeaking(at: .immediate)
        guard let voice, let folder = NaturalVoiceStore.folder else {
            preview = nil
            return
        }
        let synthesizer = NaturalVoiceSynthesizer(folder: folder, voice: voice)
        preview = synthesizer
        synthesizer.speak(AVSpeechUtterance(string: "This voice will read your articles."))
    }
}
