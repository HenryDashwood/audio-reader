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

nonisolated private func retryJob(_ id: String, status: String, rows: [(String, String)]) -> SubscriptionImportJob {
    let items = rows.enumerated().map { index, row in
        SubscriptionImportItem(id: index, title: row.0, host: "example.org", status: row.1,
            message: nil, selected: true, retryable: row.1 == "failed", feedID: nil)
    }
    return SubscriptionImportJob(id: id, status: status, duplicates: 0, folders: false, total: items.count,
        finished: items.filter { $0.status != "pending" }.count, added: items.filter { $0.status == "added" }.count,
        alreadyFollowing: 0, failed: items.filter { $0.status == "failed" }.count, notImported: 0, items: items)
}

private actor ImportAPI: SubscriptionImportAPI {
    var starts: [(String, [Int], String)] = []
    var retries: [(job: String, request: String)] = []
    private var currentJob = importJob()
    func report(_ job: SubscriptionImportJob) { currentJob = job }
    var failStart = true
    var previewContinuation: CheckedContinuation<SubscriptionImportJob, Never>?
    var holdPreview = false
    func hold() { holdPreview = true }
    func isWaiting() -> Bool { previewContinuation != nil }
    func resume() { previewContinuation?.resume(returning: importJob()); previewContinuation = nil }
    var holdStatus = false
    var statusContinuation: CheckedContinuation<SubscriptionImportJob?, Never>?
    var previews: [Data] = []
    func delayStatus() { holdStatus = true }
    func waitingForStatus() -> Bool { statusContinuation != nil }
    func releaseStatus(returning job: SubscriptionImportJob? = nil) {
        statusContinuation?.resume(returning: job)
        statusContinuation = nil
    }
    func current() async throws -> SubscriptionImportJob? {
        if holdStatus { return await withCheckedContinuation { statusContinuation = $0 } }
        return currentJob
    }
    func preview(_ data: Data) async throws -> SubscriptionImportJob {
        previews.append(data)
        if holdPreview { return await withCheckedContinuation { previewContinuation = $0 } }
        return importJob()
    }
    func start(id: String, entries: [Int], requestID: String) async throws -> SubscriptionImportJob {
        starts.append((id, entries, requestID))
        if failStart { failStart = false; throw URLError(.networkConnectionLost) }
        return importJob("queued")
    }
    func stop(id: String) async throws -> SubscriptionImportJob { importJob("stopped") }
    func retry(id: String, requestID: String) async throws -> SubscriptionImportJob {
        retries.append((id, requestID))
        if retries.count == 1 { throw URLError(.networkConnectionLost) }
        if id != currentJob.id { return currentJob }  // Replay of the request that created this job.
        let pending = currentJob.items.filter { $0.retryable && $0.status == "failed" }
        return retryJob("next", status: "queued", rows: pending.map { ($0.title, "pending") })
    }
}

@Suite("Subscription import") @MainActor
struct SubscriptionImportTests {
    @Test func previewSelectsOnlyEligibleRowsAndStartsWithoutConfirmation() async {
        let api = ImportAPI()
        let model = SubscriptionImportModel(api: api)
        await model.load()
        #expect(model.selected == [7])
        await model.start()
        #expect(await api.starts.count == 1)
    }

    @Test func lostStartResponseReusesTheExactRequestAndSelection() async {
        let api = ImportAPI()
        let model = SubscriptionImportModel(api: api)
        await model.load()
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

    @Test func checkingStatusFindsAcceptedRetryAndNextRetryTargetsItsRemainingFailure() async throws {
        let api = ImportAPI()
        let model = SubscriptionImportModel(api: api)
        await api.report(retryJob("original", status: "completed", rows: [("Podcast", "failed"), ("Publication", "failed")]))
        await model.load()
        await model.retry()
        #expect(model.error != nil)

        // Check import status discovers the accepted retry. The progress poll later sees its result.
        await api.report(retryJob("accepted", status: "queued", rows: [("Podcast", "pending"), ("Publication", "pending")]))
        await model.load()
        #expect(model.job?.active == true && model.error == nil)
        await api.report(retryJob("accepted", status: "completed", rows: [("Podcast", "added"), ("Publication", "failed")]))
        await model.load()
        await model.retry()

        let calls = await api.retries
        try #require(calls.count == 2)
        #expect(calls.map(\.job) == ["original", "accepted"])
        #expect(calls[0].request != calls[1].request)
        #expect(model.job?.active == true)
        #expect(model.job?.items.map(\.title) == ["Publication"])
    }

    @Test func checkingStatusStillShowsOriginalJobSoRetryReusesUnconfirmedRequest() async throws {
        let api = ImportAPI()
        let model = SubscriptionImportModel(api: api)
        await api.report(retryJob("original", status: "completed", rows: [("Publication", "failed")]))
        await model.load()
        await model.retry()
        #expect(model.error != nil)
        await model.load()
        #expect(model.job?.id == "original")
        await model.retry()

        let calls = await api.retries
        try #require(calls.count == 2)
        #expect(calls.map(\.job) == ["original", "original"])
        #expect(calls[0].request == calls[1].request)
    }

    @Test func selectedFileIsReviewedWhenForegroundStatusCheckFinishesLate() async {
        let api = ImportAPI()
        let model = SubscriptionImportModel(api: api)
        await api.delayStatus()
        let status = Task { await model.load() }
        while !(await api.waitingForStatus()) { await Task.yield() }
        let bytes = Data("<opml/>".utf8)
        await model.preview(bytes)
        await api.releaseStatus()
        await status.value
        #expect(await api.previews == [bytes])
        #expect(model.job?.draft == true)
        #expect(model.selected == [7])
    }

    @Test func startDuringStatusCheckDoesNotClaimAnUnsentRequest() async {
        let api = ImportAPI()
        let model = SubscriptionImportModel(api: api)
        await model.load()
        await api.delayStatus()
        let status = Task { await model.load() }
        while !(await api.waitingForStatus()) { await Task.yield() }
        await model.start()
        await api.releaseStatus(returning: importJob())
        await status.value
        #expect(await api.starts.isEmpty)
        #expect(!model.uncertainStart)
        model.chooseAnother()
        #expect(model.job == nil)
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

    @Test(arguments: [false, true])
    func leavingImportWhileFilesIsReadingDiscardsTheFileAndAnyReadError(fails: Bool) async {
        let api = ImportAPI()
        let model = SubscriptionImportModel(api: api)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let task = Task {
            await model.previewFile(.success([URL(fileURLWithPath: "/original.opml")])) { _ in
                entered.continuation.finish()
                // File providers can finish their read even after the view task is cancelled.
                let read = Task { for await _ in release.stream {} }
                await read.value
                if fails { throw CocoaError(.fileReadUnknown) }
                return Data("old file".utf8)
            }
        }
        for await _ in entered.stream {}
        task.cancel()
        release.continuation.finish()
        await task.value
        #expect(await api.previews.isEmpty)
        #expect(model.job == nil && model.error == nil)
    }

    @Test func cancellingFilesKeepsImportQuietButAnUnreadableFileExplainsTheFailure() async {
        let model = SubscriptionImportModel(api: ImportAPI())
        await model.previewFile(.failure(CocoaError(.userCancelled)))
        #expect(model.error == nil)
        await model.previewFile(.failure(CocoaError(.fileReadUnknown)))
        #expect(model.error?.contains("couldn't be opened") == true)
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
        #expect(json["public_feeds_confirmed"] == nil)
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
