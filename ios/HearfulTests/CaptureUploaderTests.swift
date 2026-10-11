import Foundation
import Synchronization
import Testing
@testable import Hearful

private actor CaptureUploadTransport {
    var replies: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ replies: [(Int, String)]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let (status, body) = replies.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct CaptureUploaderTests {
    private let account = CaptureInbox.Account(userID: "alice", server: URL(string: "https://api.example")!)
    private let article = #"{"id":42,"content_id":7,"capture_error":null}"#
    private let prepared = #"{"episode_id":42,"content_id":7,"text":"The complete article, including its final paragraph."}"#
    private func makeInbox() throws -> (CaptureInbox, CaptureInbox.Capture) {
        let inbox = CaptureInbox(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        try inbox.configure(account)
        let capture = try inbox.save(url: URL(string: "https://publisher.example/story")!, title: "A story",
            html: "<article><p>Complete captured text.</p></article>", contentFormat: "article", replaceExisting: true)
        return (inbox, capture)
    }

    @Test func completesPreparationBeforeAcknowledgingAndPreservesCapturePayload() async throws {
        let (inbox, capture) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory!) }
        let transport = CaptureUploadTransport([(200, article), (200, prepared)])
        let credentials = CaptureSessionStore.Session(account: account, token: "test-token")
        let uploader = CaptureUploader(transport: { try await transport.send($0) }, session: { credentials })
        try await uploader.finish(capture, inbox: inbox)
        #expect(inbox.pending(for: account).isEmpty)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/saved/replace")
        let body = try #require(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        #expect(body["html"] as? String == capture.html)
        #expect(body["content_format"] as? String == "article")
        #expect(body["saved_at"] != nil)
        #expect(requests[1].url?.query == "content_id=7")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    @Test func onlyExplicitMissingSaveAllowsCreateFallback() async throws {
        let (inbox, capture) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory!) }
        let transport = CaptureUploadTransport([(404, #"{"detail":"Save this article before replacing its text."}"#), (200, article), (200, prepared)])
        let credentials = CaptureSessionStore.Session(account: account, token: "test-token")
        try await CaptureUploader(transport: { try await transport.send($0) }, session: { credentials }).finish(capture, inbox: inbox)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/saved/replace", "/saved", "/episodes/42/text"])
        #expect(requests[0].httpBody == requests[1].httpBody)
    }

    @Test(arguments: [401, 404, 422, 500]) func failuresRetainTheOriginalCapture(status: Int) async throws {
        let (inbox, capture) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory!) }
        let transport = CaptureUploadTransport([(status, #"{"detail":"Unavailable"}"#)])
        let credentials = CaptureSessionStore.Session(account: account, token: "test-token")
        await #expect(throws: Error.self) {
            try await CaptureUploader(transport: { try await transport.send($0) }, session: { credentials }).finish(capture, inbox: inbox)
        }
        #expect(inbox.pending(for: account).map(\.id) == [capture.id])
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [#"{"episode_id":42,"content_id":7,"text":""}"#,
                      #"{"episode_id":42,"content_id":8,"text":"Wrong version"}"#,
                      #"{"episode_id":99,"content_id":7,"text":"Wrong article"}"#])
    func invalidPreparedTextCannotReportSuccess(text: String) async throws {
        let (inbox, capture) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory!) }
        let transport = CaptureUploadTransport([(200, article), (200, text)])
        let credentials = CaptureSessionStore.Session(account: account, token: "test-token")
        await #expect(throws: Error.self) {
            try await CaptureUploader(transport: { try await transport.send($0) }, session: { credentials }).finish(capture, inbox: inbox)
        }
        #expect(inbox.pending(for: account).count == 1)
    }

    @Test func retryAfterLostResponseKeepsOneCaptureUntilSuccessfulPreparation() async throws {
        let (inbox, capture) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory!) }
        let credentials = CaptureSessionStore.Session(account: account, token: "test-token")
        let offline = CaptureUploadTransport([(200, article)])
        await #expect(throws: Error.self) {
            try await CaptureUploader(transport: { try await offline.send($0) }, session: { credentials }).finish(capture, inbox: inbox)
        }
        #expect(inbox.pending(for: account).map(\.id) == [capture.id])
        let online = CaptureUploadTransport([(200, article), (200, prepared)])
        try await CaptureUploader(transport: { try await online.send($0) }, session: { credentials }).finish(capture, inbox: inbox)
        #expect(inbox.pending(for: account).isEmpty)
    }

    @Test func changedAccountCannotReceiveFallbackOrAcknowledgeCapture() async throws {
        let (inbox, capture) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory!) }
        let credentials = Mutex<CaptureSessionStore.Session?>(.init(account: account, token: "test-token"))
        let transport = CaptureUploadTransport([(404, #"{"detail":"Save this article before replacing its text."}"#)])
        let uploader = CaptureUploader(transport: { request in
            let result = try await transport.send(request)
            credentials.withLock { $0 = nil }
            return result
        }, session: { credentials.withLock { $0 } })
        await #expect(throws: Error.self) { try await uploader.finish(capture, inbox: inbox) }
        #expect(await transport.requests.count == 1)
        #expect(inbox.pending(for: account).count == 1)
    }

    @Test func wrongAccountNeverUploads() async throws {
        let (inbox, capture) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory!) }
        let transport = CaptureUploadTransport([])
        let credentials = CaptureSessionStore.Session(account: .init(userID: "bob", server: account.server), token: "other-token")
        await #expect(throws: Error.self) {
            try await CaptureUploader(transport: { try await transport.send($0) }, session: { credentials }).finish(capture, inbox: inbox)
        }
        #expect(await transport.requests.isEmpty)
        #expect(inbox.pending(for: account).count == 1)
    }
    @Test(arguments: [#"{"id":42,"content_id":null,"capture_error":"The full article could not be retrieved."}"#,
                      #"{"id":42,"content_id":null,"capture_error":null}"#])
    func unpreparedLinksRemainRetryable(metadata: String) async throws {
        let (inbox, capture) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory!) }
        let transport = CaptureUploadTransport([(200, metadata)])
        let credentials = CaptureSessionStore.Session(account: account, token: "test-token")
        await #expect(throws: Error.self) {
            try await CaptureUploader(transport: { try await transport.send($0) }, session: { credentials }).finish(capture, inbox: inbox)
        }
        #expect(await transport.requests.count == 1)
        #expect(inbox.pending(for: account).count == 1)
    }

    @Test func dismissalKeepsTheCaptureForRetry() async throws {
        let (inbox, capture) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory!) }
        let credentials = CaptureSessionStore.Session(account: account, token: "test-token")
        await #expect(throws: CancellationError.self) {
            try await CaptureUploader(transport: { _ in throw CancellationError() }, session: { credentials }).finish(capture, inbox: inbox)
        }
        #expect(inbox.pending(for: account).map(\.id) == [capture.id])
    }

}
