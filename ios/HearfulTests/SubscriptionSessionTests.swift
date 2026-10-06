import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import Hearful

@Suite("Subscription screens do not block Settings")
@MainActor
struct SubscriptionSessionTests {
    private let server = URL(string: "https://example.invalid")!

    @Test func constructingDestinationsDoesNotLoadCredentials() {
        let reads = Mutex(0)
        let load: @Sendable () async -> SubscriptionSession = {
            reads.withLock { $0 += 1 }
            return SubscriptionSession(token: "test", server: URL(string: "https://example.invalid")!)
        }
        // SwiftUI may build both destinations while building Settings, even
        // though neither screen is on display yet.
        _ = SubscriptionImportView(loadSession: load).body
        _ = SubscriptionExportView(loadSession: load).body
        #expect(reads.withLock { $0 } == 0)
    }

    @Test func credentialDiscoveryAndValidationRunOffTheMainThread() async {
        let session = await SubscriptionSession.capture(readToken: {
            #expect(!Thread.isMainThread)
            return "original"
        }, server: server)
        #expect(session.token == "original")
        #expect(session.server == server)
        let valid = await session.isCurrent(readToken: {
            #expect(!Thread.isMainThread)
            return "original"
        }, server: server)
        #expect(valid)
        #expect(!(await session.isCurrent(readToken: { "replacement" }, server: server)))
        #expect(!(await session.isCurrent(readToken: { "original" }, server: URL(string: "https://other.invalid")!)))
    }

    @Test func leavingTheAccountDuringExportCredentialLoadingNeverSendsARequest() async {
        let transport = FakeTransport(json: "<opml/>")
        let delay = ControlledDelay()
        let model = SubscriptionExportModel(
            api: SubscriptionExportClient(baseURL: server, token: "original", transport: transport),
            validSession: { try? await delay.wait(for: .seconds(1)); return true })
        let task = Task { await model.prepare() }
        while delay.pendingCount == 0 { await Task.yield() }
        #expect(model.busy)
        // A second tap must not race the suspended credential check.
        await model.prepare()
        #expect(delay.pendingCount == 1)
        model.clear()
        delay.elapse()
        await task.value
        #expect(transport.lastRequest == nil)
        #expect(model.document == nil)
        #expect(!model.busy)
    }

    @Test func leavingTheAccountDuringImportCredentialLoadingNeverSendsTheFile() async {
        let transport = FakeTransport(json: "null")
        let delay = ControlledDelay()
        let model = SubscriptionImportModel(
            api: SubscriptionImportClient(baseURL: server, token: "original", transport: transport),
            validSession: { try? await delay.wait(for: .seconds(1)); return true })
        let task = Task { await model.preview(Data("<opml/>".utf8)) }
        while delay.pendingCount == 0 { await Task.yield() }
        model.invalidate()
        delay.elapse()
        await task.value
        #expect(transport.lastRequest == nil)
        #expect(model.job == nil)
        #expect(!model.busy)
    }
}
