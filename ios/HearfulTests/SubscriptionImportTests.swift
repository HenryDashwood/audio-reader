import Foundation
import Testing
@testable import Hearful

nonisolated private func importJob(_ status: String = "draft", id: String = "review") -> SubscriptionImportJob {
    SubscriptionImportJob(id: id, status: status, duplicates: 1, folders: true, total: 1,
        finished: 0, added: 0, alreadyFollowing: 0, failed: 0, notImported: 0,
        items: [SubscriptionImportItem(id: 7, title: "Café & 科学", host: "example.org", status: "ready",
            message: nil, selected: false, retryable: false, feedID: nil),
            SubscriptionImportItem(id: 8, title: "Private", host: "", status: "invalid",
            message: "Not supported", selected: false, retryable: false, feedID: nil)])
}

private actor ImportAPI: SubscriptionImportAPI {
    var starts: [(String, [Int], String)] = []
    var failStart = true
    var previewContinuation: CheckedContinuation<SubscriptionImportJob, Never>?
    var holdPreview = false
    func hold() { holdPreview = true }
    func isWaiting() -> Bool { previewContinuation != nil }
    func resume() { previewContinuation?.resume(returning: importJob()); previewContinuation = nil }
    func current() async throws -> SubscriptionImportJob? { importJob() }
    func preview(_ data: Data) async throws -> SubscriptionImportJob {
        if holdPreview { return await withCheckedContinuation { previewContinuation = $0 } }
        return importJob()
    }
    func start(id: String, entries: [Int], requestID: String) async throws -> SubscriptionImportJob {
        starts.append((id, entries, requestID))
        if failStart { failStart = false; throw URLError(.networkConnectionLost) }
        return importJob("queued")
    }
    func stop(id: String) async throws -> SubscriptionImportJob { importJob("stopped") }
    func retry(id: String, requestID: String) async throws -> SubscriptionImportJob { importJob("queued", id: "retry") }
}

@Suite("Subscription import") @MainActor
struct SubscriptionImportTests {
    @Test func previewSelectsOnlyEligibleRowsAndRequiresPublicConfirmation() async {
        let api = ImportAPI()
        let model = SubscriptionImportModel(api: api)
        await model.load()
        #expect(model.selected == [7])
        await model.start()
        #expect(await api.starts.isEmpty)
        model.publicFeeds = true
        await model.start()
        #expect(await api.starts.count == 1)
    }

    @Test func lostStartResponseReusesTheExactRequestAndSelection() async {
        let api = ImportAPI()
        let model = SubscriptionImportModel(api: api)
        await model.load()
        model.publicFeeds = true
        await model.start()
        #expect(model.uncertainStart)
        #expect(model.error != nil)
        model.chooseAnother()
        #expect(model.job?.id == "review")
        model.selected = [8] // Even a programmatic change must not alter the replay.
        await model.start()
        let calls = await api.starts
        #expect(calls.count == 2)
        #expect(calls[0].2 == calls[1].2)
        #expect(calls[1].1 == [7])
        #expect(model.job?.active == true)
        #expect(!model.uncertainStart)
    }

    @Test func invalidationDiscardsLateFileResponse() async {
        let api = ImportAPI()
        await api.hold()
        let model = SubscriptionImportModel(api: api)
        let task = Task { await model.preview(Data("file".utf8)) }
        while !(await api.isWaiting()) { await Task.yield() }
        model.invalidate()
        await api.resume()
        await task.value
        #expect(model.job == nil)
        #expect(!model.busy)
    }

    @Test func changedAccountDoesNotSendFile() async {
        let model = SubscriptionImportModel(api: ImportAPI(), validSession: { false })
        await model.preview(Data("file".utf8))
        #expect(model.job == nil)
    }

    @Test func transportUsesRawFileAndCapturedCredentials() async throws {
        let transport = FakeTransport(json: "null")
        let client = SubscriptionImportClient(baseURL: URL(string: "https://example.org")!, token: "original", transport: transport)
        #expect(try await client.current() == nil)
        #expect(transport.lastRequest?.url?.path == "/subscription-imports/current")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer original")
        let bytes = Data("<opml/>".utf8)
        _ = try? await client.preview(bytes) // null deliberately cannot decode a preview.
        #expect(transport.lastRequest?.httpBody == bytes)
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/xml")
    }

    @Test func serverPreviewDecodesAllReviewFields() async throws {
        let payload = #"{"id":"review","status":"draft","duplicates":1,"folders":true,"total":0,"finished":0,"added":0,"already_following":0,"failed":0,"not_imported":0,"items":[{"id":7,"title":"Café & 科学","host":"example.org","status":"ready","message":null,"selected":false,"retryable":false,"feed_id":42}]}"#
        let client = SubscriptionImportClient(baseURL: URL(string: "https://example.org")!, token: "token", transport: FakeTransport(json: payload))
        let job = try await client.preview(Data("<opml/>".utf8))
        #expect(job.draft && job.folders)
        #expect(job.items.first?.title == "Café & 科学")
        #expect(job.items.first?.feedID == 42)
        #expect(job.alreadyFollowing == 0 && job.notImported == 0)
    }

    @Test func startWireContractAndSafeUnavailableMessage() async throws {
        let transport = FakeTransport(status: 404, json: "{}")
        let client = SubscriptionImportClient(baseURL: URL(string: "https://example.org")!, token: "token", transport: transport)
        do { _ = try await client.start(id: "review", entries: [7], requestID: "stable"); Issue.record("Expected unavailable") }
        catch let error as APIError { #expect(error.spokenResponse.contains("isn't available")) }
        let body = try #require(transport.lastRequest?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["request_id"] as? String == "stable")
        #expect(json["entry_ids"] as? [Int] == [7])
        #expect(json["public_feeds_confirmed"] as? Bool == true)
    }

    @Test func fileReaderRejectsEmptyAndOversizedFilesAndReadsUnicode() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opml")
        defer { try? FileManager.default.removeItem(at: url) }
        for bytes in [Data(), Data(repeating: 32, count: 5 * 1024 * 1024 + 1)] {
            try bytes.write(to: url)
            await #expect(throws: CocoaError.self) { try await SubscriptionImportView.readFile(url) }
        }
        let bytes = Data("<opml><body>科学</body></opml>".utf8)
        try bytes.write(to: url)
        #expect(try await SubscriptionImportView.readFile(url) == bytes)
    }
}
