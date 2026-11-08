import Foundation
import Testing
@testable import Hearful

private actor SavedLibraryTransport: DataTransport {
    var rows: [Episode]
    var textStatus = 200
    var textOffline = false
    var wrongTextVersion = false
    func setText(status: Int = 200, offline: Bool = false, wrongVersion: Bool = false) {
        textStatus = status; textOffline = offline; wrongTextVersion = wrongVersion
    }
    var rejectDeletion = false
    var suspendReplacement = false
    var replacementSucceeds = false
    private var replacement: CheckedContinuation<Void, Never>?
    private(set) var requests: [String] = []

    init(episode: Episode) { rows = [episode] }
    func setCompleted(_ value: Bool) { rows[0].completed = value }
    func acceptReplacement(_ updated: Episode) {
        rows = [updated]
        replacementSucceeds = true
    }
    func failDeletion() { rejectDeletion = true }
    func holdReplacement(succeeds: Bool) { suspendReplacement = true; replacementSucceeds = succeeds }
    func releaseReplacement() { replacement?.resume(); replacement = nil }
    var replacing: Bool { replacement != nil }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        requests.append("\(request.httpMethod ?? "GET") \(path)")
        var status = 200
        let data: Data
        if request.httpMethod == "DELETE" {
            if rejectDeletion {
                status = 503
                data = Data(#"{"detail":"Try again later."}"#.utf8)
            } else {
                rows = []
                data = Data()
            }
        } else if path == "/saved/replace" || path == "/saved/42/retry" {
            if suspendReplacement {
                await withCheckedContinuation { replacement = $0 }
            }
            if replacementSucceeds {
                data = try JSONEncoder().encode(rows[0])
            } else {
                status = 422
                data = Data(#"{"detail":"Could not replace the text. Your saved copy is unchanged."}"#.utf8)
            }
        } else if path == "/saved" && request.httpMethod == "POST" {
            data = try JSONEncoder().encode(rows[0])
        } else if path == "/episodes/42/text" {
            if textOffline { throw URLError(.notConnectedToInternet) }
            status = textStatus
            data = status == 200
                ? try JSONEncoder().encode(EpisodeText(episodeID: wrongTextVersion ? 99 : 42, contentID: rows.first?.contentID, title: "Saved article", text: "The complete saved article."))
                : Data(#"{"detail":{"spoken_response":"Download unavailable."}}"#.utf8)
        } else {
            data = try JSONEncoder().encode(rows)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
struct SavedLibraryTests {
    private let server = URL(string: "https://example.invalid")!
    private var episode: Episode {
        Episode(id: 42, title: "Saved article", description: nil, audioURL: nil,
                durationSeconds: nil, publishedAt: nil, link: URL(string: "https://publisher.example/story")!,
                hasText: false, captureError: "The site refused the request.")
    }

    private func setup(_ directory: URL, transport: SavedLibraryTransport, announce: @escaping (String) -> Void = { _ in }) throws -> (SavedLibrary, CaptureInbox, OfflineCache) {
        let inbox = CaptureInbox(directory: directory.appending(path: "inbox"))
        try inbox.configure(.init(userID: "first", server: server))
        let cache = OfflineCache(directory: directory.appending(path: "cache"))
        let model = SavedLibrary(api: HearfulAPI(baseURL: server, transport: transport),
                                 inbox: inbox, cache: cache, isSignedIn: { true }, announce: announce)
        return (model, inbox, cache)
    }

    @Test func closedLinkFormCannotSaveTheReplacementDraft() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = CaptureInbox(directory: directory)
        let first = CaptureInbox.Account(userID: "first", server: URL(string: "https://example.invalid")!)
        let second = CaptureInbox.Account(userID: "second", server: first.server)
        try inbox.configure(first)
        var draft = SavedLinkDraft()
        draft.open(account: first, scope: "first-session")
        draft.address = "https://example.invalid/first"
        let original = try #require(draft.form)
        draft.form = nil
        draft.open(account: first, scope: "first-session")
        #expect(draft.address == "https://example.invalid/first")
        let closedSave = draft.save(original, scope: "first-session", inbox: inbox)
        #expect(!closedSave)
        let reopened = try #require(draft.form)

        try inbox.configure(second)
        let accountChangedSave = draft.save(reopened, scope: "second-session", inbox: inbox)
        #expect(!accountChangedSave)
        draft.open(account: second, scope: "second-session")
        #expect(draft.address.isEmpty)
        draft.address = "https://example.invalid/second"
        let replacement = try #require(draft.form)
        draft.edit("https://example.invalid/stale", in: reopened, scope: "second-session")
        let lateSave = draft.save(reopened, scope: "second-session", inbox: inbox)
        #expect(!lateSave)
        #expect(inbox.pending(for: first).isEmpty && inbox.pending(for: second).isEmpty)
        let freshSave = draft.save(replacement, scope: "second-session", inbox: inbox)
        #expect(freshSave)
        let duplicateSave = draft.save(replacement, scope: "second-session", inbox: inbox)
        #expect(!duplicateSave)
        #expect(inbox.pending(for: second).map(\.url.absoluteString) == ["https://example.invalid/second"])
    }

    @Test func refreshMovesBrowserResavedArticleOutOfFinishedEvenWithCachedFinishedCopy() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var finished = episode
        finished.completed = true
        let transport = SavedLibraryTransport(episode: finished)
        let (model, _, cache) = try setup(directory, transport: transport)
        await model.load()
        #expect(model.episodes.first?.completed == true)
        await transport.setCompleted(false)
        await model.load()
        #expect(model.episodes.map(\.id) == [finished.id])
        #expect(model.episodes.first?.completed == false)
        #expect(cache.load([Episode].self, for: .savedArticles)?.first?.completed == false)
    }

    @Test func oldAccountsFailedPDFRetryCannotRestoreItsRowOrErrorAfterSwitch() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = CaptureInbox(directory: directory.appending(path: "inbox"))
        let account = CaptureInbox.Account(userID: "first", server: server)
        try inbox.configure(account)
        let pdfInbox = PDFUploadInbox(directory: inbox.directory)
        let pdf = try pdfInbox.save(Data("%PDF-1.4".utf8), filename: "First account.pdf", account: account)
        let transport = SavedLibraryTransport(episode: episode)
        var reply: CheckedContinuation<Void, Never>?
        let model = SavedLibrary(api: HearfulAPI(baseURL: server, transport: transport), inbox: inbox,
                                 cache: OfflineCache(directory: directory.appending(path: "cache")),
                                 isSignedIn: { true }, uploadPDF: { _, _ in
            await withCheckedContinuation { reply = $0 }
            throw URLError(.notConnectedToInternet)
        })
        let oldLoad = Task { await model.load() }
        for _ in 0..<1000 where reply == nil { await Task.yield() }
        let finishUpload = try #require(reply)
        model.clear()
        try inbox.configure(.init(userID: "second", server: server))
        await model.load()
        let secondAccountRequests = await transport.requests
        finishUpload.resume()
        await oldLoad.value
        #expect(model.pendingPDFs.isEmpty)
        #expect(model.error == nil)
        #expect(await transport.requests == secondAccountRequests)
        #expect(pdfInbox.pending(for: account).map(\.id) == [pdf.id])
    }

    @Test func readerLinkIsPersistedBeforeAnyNetworkPreparation() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, inbox, _) = try setup(directory, transport: SavedLibraryTransport(episode: episode))
        let url = URL(string: "https://publisher.example/next?chapter=5#start")!
        try model.queueLink(url)
        let reopened = CaptureInbox(directory: inbox.directory)
        let account = try #require(inbox.account)
        let capture = try #require(reopened.pending(for: account).first)
        #expect(capture.url == url)
        #expect(capture.html == nil)
        #expect(capture.title == nil)
        #expect(model.pending.map(\.id) == [capture.id])
    }

    @Test func readerLinkDoesNotClaimSuccessWhenSignedOutOrStorageFails() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, inbox, _) = try setup(directory, transport: SavedLibraryTransport(episode: episode))
        let url = URL(string: "https://publisher.example/next")!
        let account = try #require(inbox.account)
        try FileManager.default.removeItem(at: #require(inbox.directory))
        #expect(throws: CaptureInbox.InboxError.self) { try model.queueLink(url) }
        try inbox.configure(account)
        // Keep account routing readable but make the capture directory unwritable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: #require(inbox.directory).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.directory!.path) }
        #expect(throws: (any Error).self) { try model.queueLink(url) }
        #expect(model.pending.isEmpty)
    }

    @Test func dismissalRemovesFailedReplacementAndItStaysRemovedAfterReload() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = SavedLibraryTransport(episode: episode)
        let (model, inbox, cache) = try setup(directory, transport: transport)
        let account = try #require(inbox.account)
        try inbox.save(url: episode.link!, title: "Safari title", replaceExisting: true)
        await model.load()
        #expect(model.error?.contains("Could not replace") == true)
        #expect(model.pending.count == 1)
        await model.remove(episode)
        #expect(model.episodes.isEmpty)
        #expect(model.pending.isEmpty)
        #expect(model.error == nil)
        #expect(inbox.pending(for: account).isEmpty)
        #expect(cache.load([Episode].self, for: .savedArticles)?.isEmpty == true)
        await model.load()
        #expect(model.episodes.isEmpty)
        #expect(model.error == nil)
        #expect(await transport.requests.filter { $0 == "POST /saved/replace" }.count == 1)
    }

    @Test func dismissalPreservesOtherURLsAndAccounts() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = SavedLibraryTransport(episode: episode)
        let (model, inbox, _) = try setup(directory, transport: transport)
        let first = try #require(inbox.account)
        try inbox.save(url: URL(string: "https://PUBLISHER.example:443/story#section")!)
        let different = try inbox.save(url: URL(string: "https://publisher.example/story?edition=2")!)
        let other = CaptureInbox.Account(userID: "second", server: server)
        try inbox.configure(other)
        let privateCapture = try inbox.save(url: episode.link!)
        try inbox.configure(first)
        model.episodes = [episode]
        await model.remove(episode)
        #expect(inbox.pending(for: first).map(\.id) == [different.id])
        #expect(inbox.pending(for: other).map(\.id) == [privateCapture.id])
    }

    @Test func unsuccessfulDismissalKeepsTheLocalCapture() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = SavedLibraryTransport(episode: episode)
        let (model, inbox, _) = try setup(directory, transport: transport)
        let capture = try inbox.save(url: episode.link!)
        model.episodes = [episode]
        model.pending = [capture]
        await transport.failDeletion()
        await model.remove(episode)
        #expect(model.episodes == [episode])
        #expect(model.pending.map(\.id) == [capture.id])
        #expect(inbox.pending(for: capture.account).map(\.id) == [capture.id])
        #expect(model.error != nil)
    }

    @Test(arguments: [false, true])
    func dismissalWaitsForAnInFlightSaveBeforeDeleting(succeeds: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = SavedLibraryTransport(episode: episode)
        let (model, inbox, _) = try setup(directory, transport: transport)
        try inbox.save(url: episode.link!, replaceExisting: true)
        await transport.holdReplacement(succeeds: succeeds)
        let loading = Task { await model.load() }
        for _ in 0..<1000 {
            if await transport.replacing { break }
            await Task.yield()
        }
        #expect(await transport.replacing)
        let removal = Task { await model.remove(episode) }
        await Task.yield()
        #expect(!(await transport.requests).contains("DELETE /saved/42"))
        await transport.releaseReplacement()
        await loading.value
        await removal.value
        #expect(model.episodes.isEmpty)
        #expect(model.pending.isEmpty)
        #expect(model.error == nil)
        #expect(await transport.requests.last == "DELETE /saved/42")
    }

    @Test func aRetryFailureCannotReappearAfterDismissal() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = SavedLibraryTransport(episode: episode)
        let (model, _, _) = try setup(directory, transport: transport)
        model.episodes = [episode]
        await transport.holdReplacement(succeeds: false)
        let retry = Task { await model.retry(episode) }
        for _ in 0..<1000 {
            if await transport.replacing { break }
            await Task.yield()
        }
        #expect(await transport.replacing)
        let removal = Task { await model.remove(episode) }
        await Task.yield()
        #expect(!(await transport.requests).contains("DELETE /saved/42"))
        await transport.releaseReplacement()
        await retry.value
        await removal.value
        #expect(model.episodes.isEmpty)
        #expect(model.error == nil)
        #expect(await transport.requests.last == "DELETE /saved/42")
    }

    @Test func removingPendingCaptureImmediatelyClearsItsRowAndError() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = SavedLibraryTransport(episode: episode)
        let (model, inbox, _) = try setup(directory, transport: transport)
        let capture = try inbox.save(url: episode.link!, replaceExisting: true)
        model.pending = [capture]
        model.error = "Could not replace the text."
        await model.remove(capture)
        #expect(model.pending.isEmpty)
        #expect(model.error == nil)
        #expect(inbox.pending(for: capture.account).isEmpty)
        #expect(await transport.requests.isEmpty)
    }
}

@MainActor
extension SavedLibraryTests {
    @Test(arguments: [0, 408, 429, 503])
    func temporaryDownloadFailureKeepsTheSaveAndRetriesOnlyTheDownload(status: Int) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ready = episode
        ready.hasText = true
        ready.captureError = nil
        let transport = SavedLibraryTransport(episode: ready)
        let (model, inbox, cache) = try setup(directory, transport: transport)
        try inbox.save(url: ready.link!)
        await transport.setText(status: status, offline: status == 0)
        await model.load()
        #expect(model.error == nil)
        #expect(model.pending.isEmpty)
        #expect(inbox.pending(for: try #require(inbox.account)).isEmpty)
        #expect(model.availability(ready) == .waiting)
        #expect(model.needsRetry)
        #expect(cache.load([Episode].self, for: .savedArticles)?.map(\.id) == [42])
        #expect(cache.article(episodeID: 42) == nil)
        #expect(await transport.requests.filter { $0 == "GET /episodes/42/text" }.count == 1)
        await transport.setText()
        await model.retryIfDue(reset: true)
        #expect(model.error == nil)
        #expect(model.availability(ready) == .available)
        #expect(!model.needsRetry)
        #expect(cache.article(episodeID: 42)?.text == "The complete saved article.")
        #expect(await transport.requests.filter { $0 == "POST /saved" }.count == 1)
    }

    @Test func replacingSavedTextRequiresTheOriginalReviewAndAccount() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = SavedLibraryTransport(episode: episode)
        let (model, inbox, _) = try setup(directory, transport: transport)
        let cancelled = try #require(model.reviewReplacement(episode))
        model.cancelReplacement(cancelled)
        let reopened = try #require(model.reviewReplacement(episode))
        await model.replace(cancelled)
        try inbox.configure(.init(userID: "second", server: server))
        await model.replace(reopened)
        let fresh = try #require(model.reviewReplacement(episode))
        model.cancelReplacement(reopened)
        await model.replace(reopened)
        #expect(await transport.requests.isEmpty)
        await model.replace(fresh)
        await model.replace(fresh)
        #expect(await transport.requests == ["POST /saved/replace"])
    }

    @Test func acceptedReplacementWithInterruptedDownloadRetriesOnlyTheNewText() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = episode
        original.contentID = 10
        original.hasText = true
        original.captureError = nil
        let transport = SavedLibraryTransport(episode: original)
        var announcements: [String] = []
        let (model, _, cache) = try setup(directory, transport: transport) { announcements.append($0) }
        await model.load()
        #expect(model.availability(original) == .available)
        var updated = original
        updated.contentID = 11
        await transport.acceptReplacement(updated)
        await transport.setText(offline: true)
        let review = try #require(model.reviewReplacement(original))
        await model.replace(review)
        #expect(model.episodes.first?.contentID == 11)
        #expect(model.availability(updated) == .waiting)
        #expect(cache.article(episodeID: 42, contentID: 11) == nil)
        #expect(announcements == ["Saved text replaced: Saved article. Waiting to download for offline reading."])
        await transport.setText()
        await model.download(updated)
        #expect(model.availability(updated) == .available)
        #expect(cache.article(episodeID: 42, contentID: 11)?.contentID == 11)
        #expect(await transport.requests.filter { $0 == "POST /saved/replace" }.count == 1)
    }

    @Test(arguments: [403, 404, 422, 200])
    func permanentDownloadErrorsRemainVisibleWithoutUndoingTheSave(status: Int) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ready = episode
        ready.hasText = true
        ready.captureError = nil
        let transport = SavedLibraryTransport(episode: ready)
        let (model, inbox, cache) = try setup(directory, transport: transport)
        try inbox.save(url: ready.link!)
        await transport.setText(status: status, wrongVersion: status == 200)
        await model.load()
        #expect(model.error == nil)
        #expect(model.pending.isEmpty)
        guard case .failed = model.availability(ready) else {
            Issue.record("Permanent download error was hidden")
            return
        }
        #expect(cache.article(episodeID: 42) == nil)
    }
}
