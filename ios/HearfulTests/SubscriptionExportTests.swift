import Foundation
import Testing
@testable import Hearful

private actor ExportAPI: SubscriptionExportAPI {
    var continuation: CheckedContinuation<Data, Never>?
    func export() async throws -> Data { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: Data("<opml/>".utf8)); continuation = nil }
    var waiting: Bool { continuation != nil }
}

@Suite("Subscription export") @MainActor
struct SubscriptionExportTests {
    @Test func preservesXMLAndUsesAuthenticatedUncachedRequest() async throws {
        let xml = "<?xml version=\"1.0\"?><opml><body>科学 &amp; Café</body></opml>"
        let transport = FakeTransport(json: xml)
        let client = SubscriptionExportClient(baseURL: URL(string: "https://example.org")!, token: "captured", transport: transport)
        #expect(try await client.export() == Data(xml.utf8))
        #expect(transport.lastRequest?.url?.path == "/feeds/export")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer captured")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Accept") == "text/x-opml")
        #expect(transport.lastRequest?.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(OPMLDocument.contentType.preferredFilenameExtension == "opml")
    }
    @Test func emptyLibraryErrorReachesTheExportScreen() async {
        let client = SubscriptionExportClient(transport: FakeTransport(status: 409,
            json: #"{"detail":{"spoken_response":"No feeds to export."}}"#))
        let model = SubscriptionExportModel(api: client)
        await model.prepare()
        #expect(model.document == nil)
        #expect(model.error == "No feeds to export.")
        #expect(!model.busy)
    }
    @Test func lateExportCannotSurviveLeavingTheAccount() async {
        let api = ExportAPI()
        let model = SubscriptionExportModel(api: api)
        let task = Task { await model.prepare() }
        while !(await api.waiting) { await Task.yield() }
        model.clear()
        await api.finish()
        await task.value
        #expect(model.document == nil)
        #expect(!model.busy)
    }
    @Test func changedCredentialsDiscardTheResponse() async {
        let api = ExportAPI()
        var current = true
        let model = SubscriptionExportModel(api: api, validSession: { current })
        let task = Task { await model.prepare() }
        while !(await api.waiting) { await Task.yield() }
        current = false
        await api.finish()
        await task.value
        #expect(model.document == nil)
    }
}
