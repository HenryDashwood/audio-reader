import Foundation
import Synchronization
import Testing
@testable import Hearful

struct PDFImportTests {
    @Test(arguments: [nil, "", "  "] as [String?])
    func pendingCapturesAlwaysHaveReadableTitles(title: String?) throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = CaptureInbox(directory: directory)
        try inbox.configure(.init(userID: "alice", server: URL(string: "https://example.com")!))
        let capture = try inbox.save(url: URL(string: "https://arxiv.org/pdf/1706.03762")!, title: title, contentFormat: "pdf")
        #expect(capture.displayTitle == "1706.03762")
        #expect(inbox.pending(for: capture.account).first?.displayTitle == "1706.03762")
    }

    @Test(arguments: [true, false])
    @MainActor func newerCapabilityCheckOwnsTheImportButton(switchAccounts: Bool) async {
        let access = SavedPDFAccess()
        let first = CaptureInbox.Account(userID: "first", server: URL(string: "https://example.invalid")!)
        var current = first
        await access.refresh(account: { current }) { _ in
            if switchAccounts { current = CaptureInbox.Account(userID: "second", server: first.server) }
            await access.refresh(account: { current }) { _ in PDFCapability(enabled: true, consented: true) }
            throw URLError(.networkConnectionLost)
        }
        #expect(access.enabled)
        await access.refresh(account: { current }) { _ in
            await access.refresh(account: { current }) { _ in PDFCapability(enabled: false, consented: false) }
            return PDFCapability(enabled: true, consented: true)
        }
        #expect(!access.enabled)
    }

    @MainActor @Test(arguments: [false, true])
    func checkingAccessAfterAnErrorKeepsTheNewerImportPermission(lateFailure: Bool) async {
        let access = SavedPDFAccess()
        let owner = CaptureInbox.Account(userID: "reader", server: URL(string: "https://example.invalid")!)
        await access.refresh(account: { owner }) { _ in throw URLError(.notConnectedToInternet) }
        #expect(access.error != nil && access.canCheckAgain)
        #expect(access.capability == nil)
        await access.refresh(account: { owner }) { _ in
            await access.refresh(account: { owner }) { _ in PDFCapability(enabled: true, consented: true) }
            if lateFailure { throw URLError(.timedOut) }
            return PDFCapability(enabled: false, consented: false, subscription_available: true)
        }
        #expect(access.capability?.enabled == true)
        #expect(access.error == nil && !access.canCheckAgain)
    }

    @MainActor @Test(arguments: [false, true])
    func stalePickerCannotSelectAFileOrReportAnError(dismissed: Bool) throws {
        let server = URL(string: "https://example.invalid")!
        let alice = CaptureSessionStore.Session(account: .init(userID: "alice", server: server), token: "alice")
        let bob = CaptureSessionStore.Session(account: .init(userID: "bob", server: server), token: "bob")
        let first = ShareSheetUpload()
        if dismissed { first.dismiss() }
        // Exercise dismissal with the same credential as well as replacement while A is still visible.
        let current = dismissed ? alice : bob
        let file = URL.temporaryDirectory.appendingPathComponent("Alice.pdf")
        let cancelled = CocoaError(.userCancelled)
        let failure = URLError(.cannotOpenFile)
        let results: [Result<URL, Error>] = [.success(file), .failure(failure), .failure(cancelled)]
        for result in results {
            #expect(PDFPickerResult.accept(result, for: alice, current: current, presentation: first) == nil)
        }

        let second = ShareSheetUpload()
        let replacement = URL.temporaryDirectory.appendingPathComponent("Bob.pdf")
        let accepted = PDFPickerResult.accept(.success(replacement), for: bob, current: bob, presentation: second)
        #expect(try accepted?.get() == replacement)
        let rejected = PDFPickerResult.accept(.failure(failure), for: bob, current: bob, presentation: second)
        #expect(throws: URLError.self) { try rejected?.get() }
        #expect(PDFPickerResult.accept(.failure(cancelled), for: bob, current: bob, presentation: second) == nil)
    }

    @Test func fileQueueSurvivesReopeningAndRemainsBoundToAccount() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = PDFUploadInbox(directory: directory)
        let alice = CaptureInbox.Account(userID: "alice", server: URL(string: "https://example.com")!)
        let bob = CaptureInbox.Account(userID: "bob", server: alice.server)
        let data = Data("%PDF-1.7\nfixture".utf8)
        let saved = try inbox.save(data, filename: "Study.pdf", account: alice)
        let reopened = PDFUploadInbox(directory: directory)
        #expect(reopened.pending(for: alice).map(\.id) == [saved.id])
        #expect(reopened.pending(for: bob).isEmpty)
        #expect(try PDFUploadInbox.readFile(directory.appendingPathComponent("pdf-\(saved.id).pdf")) == data)
        try reopened.remove(saved)
        #expect(reopened.pending(for: alice).isEmpty)
    }
    @Test(arguments: [true, false])
    func lateFileReceiptUpdatesOnlyTheInitiatingAccountsQueue(accepted: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = PDFUploadInbox(directory: directory)
        let alice = CaptureInbox.Account(userID: "alice", server: URL(string: "https://example.invalid")!)
        let bob = CaptureInbox.Account(userID: "bob", server: alice.server)
        let active = Mutex(CaptureSessionStore.Session(account: alice, token: "first"))
        let data = Data("%PDF-1.7".utf8)
        let first = try inbox.save(data, filename: "Alice.pdf", account: alice)
        let second = try inbox.save(data, filename: "Bob.pdf", account: bob)
        do {
            try await inbox.upload(first, session: { active.withLock { $0 } }) { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first")
                active.withLock { $0 = .init(account: bob, token: "second") }
                let response = try #require(HTTPURLResponse(url: request.url!, statusCode: accepted ? 202 : 503, httpVersion: nil, headerFields: nil))
                return (Data(#"{"document_id":"one","document_status":"queued"}"#.utf8), response)
            }
        } catch CaptureUploader.Failure.changedAccount { }
        #expect(inbox.pending(for: alice).map(\.id) == (accepted ? [] : [first.id]))
        #expect(inbox.pending(for: bob).map(\.id) == [second.id])
    }

    @Test func overlappingRetriesShareOneFileUploadAndAllowRetryAfterFailure() async throws {
        let requests = PDFUploadRequests()
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let gate = AsyncStream<Void>.makeStream()
        let calls = Mutex(0)
        let send: @Sendable () async throws -> Void = {
            calls.withLock { $0 += 1 }
            for await _ in gate.stream { break }
            throw URLError(.networkConnectionLost)
        }
        let first = await requests.start(file: file, upload: send)
        let second = await requests.start(file: file, upload: send)
        gate.continuation.finish()
        for task in [first, second] {
            await #expect(throws: URLError.self) { try await task.value }
        }
        #expect(calls.withLock { $0 } == 1)
        let retry = await requests.start(file: file) { calls.withLock { $0 += 1 } }
        try await retry.value
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func invalidFilesAreRejectedAndPendingStatusSurvivesCaching() throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<html>Login</html>".utf8).write(to: url)
        #expect(throws: Error.self) { try PDFUploadInbox.readFile(url) }
        let data = Data(#"{"id":42,"title":"Study","document_id":"abc","document_status":"processing"}"#.utf8)
        let episode = try JSONDecoder().decode(Episode.self, from: data)
        #expect(episode.preparingPDF)
        let cached = try JSONDecoder().decode(Episode.self, from: JSONEncoder().encode(episode))
        #expect(cached.documentID == "abc")
        #expect(cached.preparingPDF)
    }
}
