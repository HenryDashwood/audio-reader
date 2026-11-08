import SwiftUI

@MainActor
final class SavedPDFAccess: ObservableObject {
    @Published private(set) var capability: PDFCapability?
    @Published private(set) var error: String?
    var enabled: Bool {
        error == nil && (capability?.enabled == true || capability?.subscription_available == true)
    }

    var canCheckAgain: Bool {
        error != nil || (capability?.enabled == false && capability?.subscription_available == true)
    }
    private var owner: CaptureInbox.Account?
    private var generation = 0

    func refresh(
        account: () -> CaptureInbox.Account? = { CaptureInbox.shared.account },
        request: (CaptureInbox.Account) async throws -> PDFCapability = { try await PDFImportAccess().request(for: $0) }
    ) async {
        let current = account()
        generation += 1
        let attempt = generation
        if owner != current {
            owner = current
            capability = nil
            error = nil
        }
        guard let current else { return }
        let result: Result<PDFCapability, Error>
        do {
            result = .success(try await request(current))
        } catch {
            result = .failure(error)
        }
        guard attempt == generation, current == account(), !Task.isCancelled else { return }
        switch result {
        case .success(let updated):
            capability = updated
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }
}
