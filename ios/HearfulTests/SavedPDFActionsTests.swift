import Foundation
import Testing
@testable import Hearful

@MainActor
struct SavedPDFActionsTests {
    enum Next: CaseIterable { case openB, leaveSaved, switchAccount }

    @Test(arguments: Next.allCases, [false, true])
    func onlyTheCurrentOriginalCanPresentAFileOrError(next: Next, firstFails: Bool) async throws {
        let server = URL(string: "https://magpie.invalid")!
        var session: CaptureSessionStore.Session? = .init(account: .init(userID: "alice", server: server), token: "A")
        var held: CheckedContinuation<Void, Never>?
        let actions = SavedPDFActions(session: { session }) { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            if url.path == "/documents/A/original" {
                await withCheckedContinuation { held = $0 }
                if firstFails { throw URLError(.networkConnectionLost) }
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(url.path.utf8), response)
        }
        defer { actions.dismiss() }
        let first = try #require(actions.open("A"))
        let deadline = ContinuousClock.now + .seconds(5)
        while held == nil, ContinuousClock.now < deadline { await Task.yield() }
        let reply = try #require(held)
        switch next {
        case .openB: await actions.open("B")?.value
        case .leaveSaved: actions.dismiss()
        case .switchAccount: session = .init(account: .init(userID: "bob", server: server), token: "B")
        }
        let currentFile = actions.file
        reply.resume()
        await first.value
        #expect(actions.error == nil)
        if next == .openB {
            let url = try #require(currentFile)
            #expect(actions.file == url)
            #expect(try Data(contentsOf: url) == Data("/documents/B/original".utf8))
            actions.dismiss()
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } else {
            #expect(actions.file == nil)
        }
    }
    @Test func switchingAccountsBeforeConfirmingDeletionCannotSendTheOldDocumentID() async throws {
        let server = URL(string: "https://magpie.invalid")!
        var credentials = CaptureSessionStore.Session(account: .init(userID: "first", server: server), token: "first")
        var requests: [String] = []
        var refreshes = 0
        let actions = SavedPDFActions(session: { credentials }) { request in
            let url = try #require(request.url)
            requests.append("\(request.httpMethod ?? "") \(url.path) \(request.value(forHTTPHeaderField: "Authorization") ?? "")")
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)))
        }
        let originalDocument = "shared-id"
        let original = try #require(actions.reviewDeletion(originalDocument))
        let oldConfirm = { actions.delete(original) { refreshes += 1 } }
        credentials = .init(account: .init(userID: "second", server: server), token: "second")
        await oldConfirm()?.value
        #expect(requests.isEmpty && refreshes == 0)
        let cancelled = try #require(actions.reviewDeletion(originalDocument))
        actions.cancelDeletion(cancelled)
        let fresh = try #require(actions.reviewDeletion(originalDocument))
        await actions.delete(cancelled) { refreshes += 1 }?.value
        actions.cancelDeletion(original)
        #expect(requests.isEmpty)
        await actions.delete(fresh) { refreshes += 1 }?.value
        #expect(requests == ["DELETE /documents/shared-id Bearer second"])
        #expect(refreshes == 1)
    }

    @Test(arguments: [true, false])
    func duplicateDeletionAndDismissalWhileTheRequestIsPending(succeeds: Bool) async throws {
        let credentials = CaptureSessionStore.Session(account: .init(userID: "alice", server: URL(string: "https://magpie.invalid")!), token: "A")
        var calls = 0
        var refreshes = 0
        let actions = SavedPDFActions(session: { credentials }) { request in
            calls += 1
            #expect(request.httpMethod == "DELETE")
            let url = try #require(request.url)
            #expect(url.path == "/documents/A")
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: succeeds ? 204 : 500, httpVersion: nil, headerFields: nil)))
        }
        let reviewed = try #require(actions.reviewDeletion("A"))
        let first = try #require(actions.delete(reviewed) { refreshes += 1 })
        let repeatedReview = try #require(actions.reviewDeletion("A"))
        let duplicate = actions.delete(repeatedReview) { refreshes += 1 }
        actions.dismiss()
        await first.value
        #expect(duplicate == nil)
        #expect(calls == 1)
        #expect(refreshes == (succeeds ? 1 : 0))
        #expect(actions.error == nil)
        if !succeeds {
            let retry = try #require(actions.reviewDeletion("A"))
            await actions.delete(retry) { refreshes += 1 }?.value
            #expect(calls == 2)
            #expect(actions.error != nil)
        }
    }

}
