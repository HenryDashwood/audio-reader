import Foundation
import Testing
@testable import Hearful

private actor FilingTransport: DataTransport {
    var offline = true
    var rejected = false
    var retryAfter: String?
    private(set) var bodies: [Data] = []
    func connect() { offline = false }
    func reject() { offline = false; rejected = true }
    func throttleNextRequest(seconds: String) { offline = false; retryAfter = seconds }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = request.httpBody!
        bodies.append(body)
        if offline { throw URLError(.networkConnectionLost) }
        if let retryAfter {
            self.retryAfter = nil
            return (Data(#"{"detail":{"spoken_response":"Please try again shortly."}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": retryAfter])!)
        }
        if rejected {
            return (Data(#"{"action":"unknown","spoken_response":"The selected article has changed."}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let values = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        if values?["action"] as? String == "dismiss", let id = values?["episode_id"] as? Int {
            let response = #"{"action":"dismiss","spoken_response":"Dismissed","episode":{"id":\#(id),"title":"Essay","dismissed":true}}"#
            return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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

    @Test func rateLimitedDismissalsStayHiddenAndRetryInOrder() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FilingTransport()
        await transport.throttleNextRequest(seconds: "28")
        let api = HearfulAPI(baseURL: URL(string: "https://example.invalid")!, transport: transport)
        let cache = OfflineCache(directory: directory.appending(path: "cache"))
        let second = Episode(id: 43, title: "Another essay", description: nil, audioURL: nil, durationSeconds: nil,
                             publishedAt: nil, link: nil, hasText: true)
        var waits: [TimeInterval] = []
        let queue = OfflineLibraryActions(api: api, directory: directory, scope: { owner }, cache: cache,
            blockProgress: { _, _ in }, waitToRetry: { waits.append($0) })
        try queue.enqueue(.dismissed, episode: episode)
        try queue.enqueue(.dismissed, episode: second)
        let firstID = try #require(queue.pending.first?.requestID)
        let secondID = try #require(queue.pending.last?.requestID)
        #expect(firstID != secondID)
        #expect(queue.overlay([episode, second]).allSatisfy { $0.dismissed == true })

        await queue.waitForUpload()
        #expect(waits == [28])
        #expect(queue.error == nil)
        #expect(queue.pending.isEmpty)
        let bodies = await transport.bodies
        let requests = try bodies.map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(requests.compactMap { $0["episode_id"] as? Int } == [42, 42, 43])
        #expect(requests.compactMap { $0["request_id"] as? String } == [firstID, firstID, secondID])
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
