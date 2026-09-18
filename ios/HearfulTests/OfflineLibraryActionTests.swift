import Foundation
import Testing
@testable import Hearful

private actor FilingTransport: DataTransport {
    var offline = true
    var rejected = false
    private(set) var bodies: [Data] = []
    func connect() { offline = false }
    func reject() { offline = false; rejected = true }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        bodies.append(request.httpBody!)
        if offline { throw URLError(.networkConnectionLost) }
        if rejected {
            return (Data(#"{"action":"unknown","spoken_response":"The selected article has changed."}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let response = #"{"action":"mark_played","spoken_response":"Marked as read","episode":{"id":42,"title":"Essay","has_text":true,"completed":true}}"#
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
struct OfflineLibraryActionTests {
    private let owner = String(repeating: "a", count: 64)
    private var episode: Episode {
        Episode(id: 42, title: "Essay", description: nil, audioURL: nil, durationSeconds: nil,
                publishedAt: nil, link: nil, hasText: true)
    }
    @Test func filingSurvivesRelaunchAndRetriesTheOriginalReceipt() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FilingTransport()
        let api = HearfulAPI(baseURL: URL(string: "https://example.invalid")!, transport: transport)
        let cache = OfflineCache(directory: directory.appending(path: "cache"))
        cache.save([episode], for: .savedArticles)
        let queue = OfflineLibraryActions(api: api, directory: directory, scope: { owner }, cache: cache, blockProgress: { _, _ in })
        try queue.enqueue(.played, episode: episode)
        await queue.waitForUpload()
        #expect(queue.pending.count == 1)
        #expect(queue.overlay([episode]).first?.completed == true)
        #expect(cache.load([Episode].self, for: .savedArticles)?.first?.completed == true)
        let original = try #require(await transport.bodies.first)
        await transport.connect()
        let reopened = OfflineLibraryActions(api: api, directory: directory, scope: { owner }, cache: cache, blockProgress: { _, _ in })
        reopened.retry(); await reopened.waitForUpload()
        #expect(reopened.pending.isEmpty)
        let resent = try #require(await transport.bodies.last)
        // JSON key order can vary; compare the request's decoded values.
        #expect(try JSONSerialization.jsonObject(with: original) as? NSDictionary == JSONSerialization.jsonObject(with: resent) as? NSDictionary)
    }

    @Test func pendingFilingCannotAppearInAnotherAccount() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = HearfulAPI(baseURL: URL(string: "https://example.invalid")!, transport: FilingTransport())
        let cache = OfflineCache(directory: directory.appending(path: "cache"))
        var scope = owner
        let queue = OfflineLibraryActions(api: api, directory: directory, scope: { scope }, cache: cache, blockProgress: { _, _ in })
        try queue.enqueue(.played, episode: episode); await queue.waitForUpload()
        scope = String(repeating: "b", count: 64)
        #expect(queue.overlay([episode]).first?.completed != true)
        #expect(queue.pending.isEmpty)
    }

    @Test func storageFailureDoesNotAnnounceOrApplyAFiling() throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("not a directory".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = OfflineLibraryActions(directory: url, scope: { owner }, blockProgress: { _, _ in })
        #expect(throws: (any Error).self) { try queue.enqueue(.played, episode: episode) }
        #expect(queue.pending.isEmpty)
    }

    @Test func offlineUndoTargetsOriginalChangeAndRestoresLocalState() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FilingTransport()
        let api = HearfulAPI(baseURL: URL(string: "https://example.invalid")!, transport: transport)
        let cache = OfflineCache(directory: directory.appending(path: "cache"))
        cache.save([episode], for: .recentEpisodes)
        let queue = OfflineLibraryActions(api: api, directory: directory, scope: { owner }, cache: cache, blockProgress: { _, _ in })
        try queue.enqueue(.played, episode: episode); await queue.waitForUpload()
        let originalID = try #require(queue.pending.first?.requestID)
        cache.save([Episode](), for: .recentEpisodes)
        try queue.undo(); await queue.waitForUpload()
        #expect(queue.pending.last?.undoRequestID == originalID)
        #expect(cache.load([Episode].self, for: .recentEpisodes)?.first?.id == episode.id)
        #expect(queue.overlay([episode]).first?.completed != true)
        await transport.connect()
        queue.retry(force: true); await queue.waitForUpload()
        let body = try #require(await transport.bodies.last)
        let values = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(values["undo_request_id"] as? String == originalID)
        #expect(values["action"] as? String == "undo")
        #expect(queue.pending.isEmpty)
    }

    @Test func rejectedChangeDoesNotLeaveOptimisticFlagsInCache() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FilingTransport()
        let api = HearfulAPI(baseURL: URL(string: "https://example.invalid")!, transport: transport)
        let cache = OfflineCache(directory: directory.appending(path: "cache"))
        cache.save([episode], for: .savedArticles)
        let queue = OfflineLibraryActions(api: api, directory: directory, scope: { owner }, cache: cache, blockProgress: { _, _ in })
        try queue.enqueue(.played, episode: episode); await queue.waitForUpload()
        await transport.reject()
        queue.retry(force: true); await queue.waitForUpload()
        #expect(queue.pending.isEmpty)
        #expect(cache.load([Episode].self, for: .savedArticles)?.first?.completed != true)
    }
}
