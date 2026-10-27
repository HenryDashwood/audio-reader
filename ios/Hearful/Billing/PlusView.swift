import SwiftUI
import RevenueCat

struct PlusView: View {
    @ObservedObject private var purchases = PlusStore.shared
    @State private var session = CaptureSessionStore.read()
    @State private var status: PlusStatus?
    @State private var package: Package?
    @State private var error: String?
    @State private var message: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Text("Turn PDFs into readable articles, including equations and images.")
                Text("500 pages per billing month. Unused pages do not roll over. PDFs you have already imported remain readable after cancellation.")
            }
            if let status {
                if status.unlimited {
                    Section { Text("Your account has unlimited PDF imports.") }
                } else if status.active {
                    Section("Your allowance") {
                        Text("\(status.remainingPages ?? 0) of \(status.monthlyPages) pages remaining")
                        if let date = renewalDate(status.periodEnd) { Text("Current period ends \(date, style: .date)") }
                        if status.store == "play_store" {
                            Link("Manage on Google Play", destination: URL(string: "https://play.google.com/store/account/subscriptions")!)
                        } else {
                            Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                        }
                    }
                } else if status.available, let package {
                    Section {
                        Button("Subscribe · \(package.localizedPriceString) / month") { Task { await load(purchase: package) } }
                            .disabled(purchases.busy)
                        Text("Payment is charged to your Apple Account. The subscription renews automatically each month unless cancelled in App Store settings before renewal.")
                            .font(.footnote)
                    }
                } else {
                    Text(status.available ? "The monthly subscription is temporarily unavailable. Please try again." : "Magpie Plus is not available to purchase yet.")
                }
                if status.available, !status.unlimited {
                    Button("Restore purchases") { Task { await load(restore: true) } }.disabled(purchases.busy)
                }
            }
            if purchases.busy { ProgressView("Checking subscription…") }
            if let error { Text(error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
            if let message { Text(message).accessibilityAddTraits(.updatesFrequently) }
            Button("Refresh") { Task { await load(refresh: true) } }.disabled(purchases.busy)
            Section {
                Link("Privacy Policy", destination: AppConfiguration.privacyURL)
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
        }
        .navigationTitle("Magpie Plus")
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }

    private func renewalDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func load(restore: Bool = false, purchase: Package? = nil, refresh: Bool = false) async {
        guard !purchases.busy else { return }
        error = nil
        message = nil
        do {
            guard let session else { throw CaptureUploader.Failure.signIn }
            let result = try await purchases.perform(session: session, restore: restore, purchase: purchase, refresh: refresh)
            status = result.0
            package = result.1
            if restore { message = result.0.active ? "Purchases restored." : "No active Magpie Plus subscription was found for this store account." }
            if purchase != nil, result.0.active { message = "Magpie Plus is ready. You can import PDFs now." }
        } catch { self.error = error.localizedDescription }
    }
}
