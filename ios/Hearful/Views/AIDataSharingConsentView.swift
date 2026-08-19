import SwiftUI

/// The affirmative choice shown before any words or library context can reach
/// a third-party AI provider. It is deliberately a full explanation rather
/// than a toggle whose consequence has to be found elsewhere.
struct AIDataSharingConsentView: View {
    @EnvironmentObject private var auth: AuthController
    let onAllowed: () -> Void
    let onNotNow: () -> Void
    @State private var saving = false
    @State private var error: String?

    init(onAllowed: @escaping () -> Void = {}, onNotNow: @escaping () -> Void) {
        self.onAllowed = onAllowed
        self.onNotNow = onNotNow
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "waveform.and.sparkles")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Allow AI data sharing?")
                    .font(.title.bold())

                Text(
                    "To understand a spoken request, Hearful sends the words recognised "
                        + "on your device to OpenRouter, which passes them to an AI model provider."
                )

                Text(
                    "It also sends recent episode titles, show names, publication dates and short "
                        + "description extracts so the AI can work out which episode you mean."
                )

                Text(
                    "Hearful never sends a voice recording, your name, email address or account "
                        + "identifier to the AI provider. A diagnostic record, including the words "
                        + "recognised, is kept for up to 30 days so mistakes can be fixed."
                )

                Link("Read the Privacy Policy", destination: AppConfiguration.privacyURL)

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Could not save your choice. \(error)")
                }

                Button {
                    Task { await allow() }
                } label: {
                    if saving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Allow AI Data Sharing")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
                .accessibilityHint(
                    "Allows spoken requests and recent episode details to be sent to OpenRouter and an AI model provider"
                )

                Button("Not Now", action: onNotNow)
                    .frame(maxWidth: .infinity)
                    .disabled(saving)
                    .accessibilityHint(
                        "Closes this screen without sharing data. You can still use Hearful on screen."
                    )
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(28)
        }
    }

    private func allow() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await auth.setAIDataSharing(granted: true)
            onAllowed()
        } catch let apiError as APIError {
            self.error = apiError.spokenResponse
            AccessibilityNotification.Announcement(apiError.spokenResponse).post()
        } catch {
            self.error = APIError.genericSpokenResponse
            AccessibilityNotification.Announcement(APIError.genericSpokenResponse).post()
        }
    }
}
