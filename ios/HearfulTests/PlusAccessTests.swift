import Foundation
import Synchronization
import Testing
@testable import Hearful

struct PlusAccessTests {
    private let account = CaptureInbox.Account(userID: "alice", server: URL(string: "https://api.example")!)
    private let payload = #"{"available":true,"active":true,"unlimited":false,"customer_id":"opaque-alice","apple_sdk_key":"appl_public","offering_id":"magpie_plus","monthly_pages":500,"used_pages":42,"remaining_pages":458,"period_end":"2026-11-27T12:00:00Z","store":"play_store"}"#

    @Test func sharedAndroidEntitlementIsReadFromTheAuthenticatedServer() async throws {
        let credentials = CaptureSessionStore.Session(account: account, token: "token")
        let api = PlusAccess(transport: { request in
            #expect(request.url?.path == "/billing/sync")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, currentSession: { credentials })
        let status = try await api.request(credentials, sync: true)
        #expect(status.active && status.store == "play_store")
        #expect(status.remainingPages == 458)
    }

    @Test func latePurchaseResponseCannotGrantAccessToAnotherAccount() async throws {
        let credentials = CaptureSessionStore.Session(account: account, token: "token")
        let current = Mutex<CaptureSessionStore.Session?>(credentials)
        let api = PlusAccess(transport: { request in
            current.withLock { $0 = nil }
            return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, currentSession: { current.withLock { $0 } })
        await #expect(throws: Error.self) { try await api.request(credentials, sync: true) }
    }

    @Test(arguments: [401, 403, 429, 503]) func failedVerificationNeverGrantsAccess(code: Int) async throws {
        let credentials = CaptureSessionStore.Session(account: account, token: "token")
        let api = PlusAccess(transport: { request in
            (Data(#"{"detail":"Try again"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }, currentSession: { credentials })
        await #expect(throws: Error.self) { try await api.request(credentials) }
    }
}
