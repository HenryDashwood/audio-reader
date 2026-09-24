import Foundation
import Testing
@testable import Hearful

private actor SavedLibraryTransport: DataTransport {
    var rows: [Episode]
    var rejectDeletion = false
    var suspendReplacement = false
    var replacementSucceeds = false
    private var replacement: CheckedContinuation<Void, Never>?
    private(set) var requests: [String] = []

    init(episode: Episode) { rows = [episode] }
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
        } else if path == "/episodes/42/text" {
            data = Data(#"{"episode_id":42,"title":"Saved article","text":"The complete saved article."}"#.utf8)
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

    private func setup(_ directory: URL, transport: SavedLibraryTransport) throws -> (SavedLibrary, CaptureInbox, OfflineCache) {
        let inbox = CaptureInbox(directory: directory.appending(path: "inbox"))
        try inbox.configure(.init(userID: "first", server: server))
        let cache = OfflineCache(directory: directory.appending(path: "cache"))
        let model = SavedLibrary(api: HearfulAPI(baseURL: server, transport: transport),
                                 inbox: inbox, cache: cache, isSignedIn: { true })
        return (model, inbox, cache)
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
