import Foundation
import StoreKit
import Testing
import UIKit
@testable import Hearful

/// Manual device exercise only. No refund request is presented during normal CI,
/// and this test bundle is never included in App Store or TestFlight builds.
@Suite("Apple sandbox refund", .serialized)
@MainActor
struct SubscriptionRefundDeviceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEARFUL_TEST_RECEIPT_DIAGNOSTICS"] == "1"))
    func sandboxReceiptIdentity() async throws {
        let environment = ProcessInfo.processInfo.environment
        let session = try #require(CaptureSessionStore.read())
        #expect(session.account.server.absoluteString == "https://audio-reader-production.up.railway.app")
        #expect(session.account.userID == environment["HEARFUL_TEST_EXPECTED_USER"])
        let staleOriginalID = try #require(UInt64(environment["HEARFUL_TEST_STAGING_TRANSACTION"] ?? ""))
        var count = 0
        for await result in StoreKit.Transaction.all {
            guard case .verified(let transaction) = result else {
                Issue.record("StoreKit supplied an unverified transaction.")
                continue
            }
            guard transaction.productID == "magpie_plus_monthly" else { continue }
            try #require(transaction.environment == .sandbox, "Only inspect test purchases.")
            print("MAGPIE_RECEIPT transaction=\(transaction.id) original=\(transaction.originalID) purchased=\(transaction.purchaseDate) expires=\(String(describing: transaction.expirationDate)) revoked=\(String(describing: transaction.revocationDate))")
            #expect(transaction.originalID != staleOriginalID, "StoreKit is returning the earlier staging tester's purchase history.")
            count += 1
            if count >= 50 { break }
        }
        #expect(count > 0, "StoreKit returned no verified Magpie test purchases.")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEARFUL_TEST_SANDBOX_REFUND"] == "1"))
    func requestSandboxRefund() async throws {
        let environment = ProcessInfo.processInfo.environment
        let expectedOriginalID = try #require(UInt64(environment["HEARFUL_TEST_REFUND_ORIGINAL_TRANSACTION"] ?? ""))
        let result = try #require(await StoreKit.Transaction.latest(for: "magpie_plus_monthly"))
        guard case .verified(let transaction) = result else {
            Issue.record("Apple did not verify the test purchase.")
            return
        }
        try #require(transaction.environment == .sandbox, "Refusing to refund a real purchase.")
        try #require(transaction.productID == "magpie_plus_monthly")
        try #require(transaction.originalID == expectedOriginalID, "Refusing to refund another tester's transaction.")
        let expiration = try #require(transaction.expirationDate)
        try #require(expiration > Date(), "Use an active test purchase to verify immediate revocation.")
        try #require(transaction.revocationDate == nil, "This purchase has already been refunded.")
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let status = try await transaction.beginRefundRequest(in: scene)
        #expect(status == .success, "Complete Apple's test refund sheet on the iPhone.")
        // Submission is not proof of backend revocation. Check RevenueCat's
        // REFUND event, webhook delivery, and the account's allowance separately.
    }
}
