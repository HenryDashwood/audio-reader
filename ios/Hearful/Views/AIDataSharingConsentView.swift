import SwiftUI

/// The affirmative choice shown before any words or library context can reach
/// a third-party AI provider.
///
/// This is app-owned permission rather than an iOS permission, so it uses the
/// same visual language without pretending to be a system alert. The actions
/// stay outside the scroll view: even at an accessibility text size, nobody
/// has to discover that the buttons exist by scrolling through legal copy.
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 6) {
                        Text("Use AI for voice requests?")
                            .font(.title2.bold())

                        Text(
                            "Hearful uses OpenRouter and an AI model provider to understand "
                                + "what you ask it to play."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    VStack(spacing: 0) {
                        DisclosureRow(
                            icon: "text.bubble",
                            title: "What is shared",
                            detail: "Recognised words and relevant episode titles, shows, dates and short descriptions."
                        )

                        Divider().padding(.leading, 42)

                        DisclosureRow(
                            icon: "lock.shield",
                            title: "What is not shared",
                            detail: "No voice recording, name, email address or account identifier."
                        )

                        Divider().padding(.leading, 42)

                        DisclosureRow(
                            icon: "clock",
                            title: "Diagnostic record",
                            detail: "The recognised words and result are kept for up to 30 days to fix mistakes."
                        )
                    }
                    .padding(.horizontal, 12)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))

                    Link("Privacy Policy", destination: AppConfiguration.privacyURL)
                        .font(.subheadline)

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityLabel("Could not save your choice. \(error)")
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)
            }

            Divider()

            VStack(spacing: 8) {
                Button {
                    Task { await allow() }
                } label: {
                    if saving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Allow")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saving)
                .accessibilityLabel("Allow AI data sharing")
                .accessibilityHint(
                    "Allows recognised words and relevant episode details to be sent to OpenRouter and an AI model provider"
                )

                Button("Not Now", action: onNotNow)
                    .frame(maxWidth: .infinity)
                    .disabled(saving)
                    .accessibilityHint(
                        "Closes without sharing data. You can still use Hearful on screen."
                    )
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.bar)
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

private struct DisclosureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
