import Foundation
import Combine
import RevenueCat

nonisolated struct PlusStatus: Decodable, Sendable {
    let available: Bool
    let active: Bool
    let unlimited: Bool
    let customerID: String
    let appleSDKKey: String
    let offeringID: String
    let monthlyPages: Int
    let usedPages: Int
    let remainingPages: Int?
    let periodEnd: String?
    let store: String?

    enum CodingKeys: String, CodingKey {
        case available, active, unlimited, store
        case customerID = "customer_id", appleSDKKey = "apple_sdk_key", offeringID = "offering_id"
        case monthlyPages = "monthly_pages", usedPages = "used_pages", remainingPages = "remaining_pages"
        case periodEnd = "period_end"
    }
}

/// Serializes SDK identity changes with purchases so an account switch cannot redirect a receipt.
@MainActor final class PlusStore: ObservableObject {
    static let shared = PlusStore()
    @Published private(set) var busy = false
    private var configuredKey: String?

    func perform(session: CaptureSessionStore.Session, restore: Bool = false, purchase: Package? = nil, refresh: Bool = false, configureOnly: Bool = false)
        async throws -> (PlusStatus, Package?) {
        guard !busy else { throw PDFUploadInbox.Failure.message("Please wait for the current purchase to finish.") }
        busy = true
        defer { busy = false }
        try check(session)
        var status = try await request(session, sync: refresh)
        try check(session)
        guard status.available, !status.unlimited else { return (status, nil) }
        guard status.appleSDKKey.hasPrefix("appl_") else {
            throw PDFUploadInbox.Failure.message("Subscriptions are not available in this build yet.")
        }
        if let configuredKey {
            guard configuredKey == status.appleSDKKey else {
                throw PDFUploadInbox.Failure.message("Restart Magpie after changing servers.")
            }
        } else {
            Purchases.configure(withAPIKey: status.appleSDKKey, appUserID: status.customerID)
            configuredKey = status.appleSDKKey
        }
        if Purchases.shared.appUserID != status.customerID {
            _ = try await Purchases.shared.logIn(status.customerID)
            try check(session)
        }
        if configureOnly { return (status, nil) }
        if restore {
            _ = try await Purchases.shared.restorePurchases()
            try check(session)
            status = try await request(session, sync: true)
        } else if let purchase {
            let result = try await Purchases.shared.purchase(package: purchase)
            try check(session)
            if !result.userCancelled { status = try await request(session, sync: true) }
        }
        try check(session)
        if status.active { return (status, nil) }
        let offerings = try? await Purchases.shared.offerings()
        try check(session)
        let package = offerings?.offering(identifier: status.offeringID)?.monthly
        return (status, package)
    }

    private func check(_ session: CaptureSessionStore.Session) throws {
        try Task.checkCancellation()
        guard CaptureSessionStore.read() == session else { throw CaptureUploader.Failure.changedAccount }
    }

    private func request(_ session: CaptureSessionStore.Session, sync: Bool = false) async throws -> PlusStatus {
        try await PlusAccess().request(session, sync: sync)
    }
}

nonisolated struct PlusAccess: Sendable {
    var transport: CaptureUploader.Transport = CaptureUploader.send
    var currentSession: @Sendable () -> CaptureSessionStore.Session? = { CaptureSessionStore.read() }

    func request(_ session: CaptureSessionStore.Session, sync: Bool = false) async throws -> PlusStatus {
        guard currentSession() == session else { throw CaptureUploader.Failure.changedAccount }
        try Task.checkCancellation()
        var request = URLRequest(url: session.account.server.appendingPathComponent(sync ? "billing/sync" : "billing/status"))
        request.httpMethod = sync ? "POST" : "GET"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard currentSession() == session else { throw CaptureUploader.Failure.changedAccount }
        guard response.statusCode == 200 else {
            struct Problem: Decodable { let detail: String }
            let message = (try? JSONDecoder().decode(Problem.self, from: data))?.detail
            throw PDFUploadInbox.Failure.message(message ?? "Subscription status is unavailable. Please try again.")
        }
        return try JSONDecoder().decode(PlusStatus.self, from: data)
    }
}
