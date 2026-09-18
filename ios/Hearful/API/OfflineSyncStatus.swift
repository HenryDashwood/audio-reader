import SwiftUI

@MainActor
final class OfflineSyncStatus: ObservableObject {
    static let shared = OfflineSyncStatus()
    @Published var message: String?

    func report(_ message: String) {
        guard self.message != message else { return }
        self.message = message
        AccessibilityNotification.Announcement(message).post()
    }
}

struct OfflineSyncNotice: View {
    @ObservedObject private var status = OfflineSyncStatus.shared
    var body: some View {
        if let message = status.message {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
