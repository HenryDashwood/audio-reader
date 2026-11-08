import Combine
import Foundation
import Testing

@testable import Hearful

@Suite("Publication sources")
struct FeedSourceTests {
    private let sourceJSON = """
        [{"id":7,"title":"Subscriber feed","url":"https://passport.example.test/feed/private-token",
          "source":"rss","is_primary":true,"is_failing":false}]
        """

    @Test func readsSourcesAndKeepsPrivateURLTokensOutOfLabels() async throws {
        let transport = FakeTransport(json: sourceJSON)
        let api = HearfulAPI(baseURL: URL(string: "https://test.local")!, transport: transport)
        let sources = try await api.feedSources(showID: 7)
        #expect(sources.count == 1)
        #expect(sources[0].isPrimary)
        #expect(sources[0].locationLabel == "passport.example.test")
        #expect(transport.lastRequest?.url?.path == "/feeds/7/sources")
        #expect(transport.lastRequest?.httpMethod == "GET")
    }

    @Test func combiningUsesExplicitSourceIDs() async throws {
        let transport = FakeTransport(status: 204, json: "")
        let api = HearfulAPI(baseURL: URL(string: "https://test.local")!, transport: transport)
        try await api.combineSource(showID: 7, sourceID: 9)
        #expect(transport.lastRequest?.url?.path == "/feeds/7/sources/9")
        #expect(transport.lastRequest?.httpMethod == "PUT")
    }

    @Test func separatingUsesSourceEndpointRatherThanUnsubscribing() async throws {
        let transport = FakeTransport(status: 204, json: "")
        let api = HearfulAPI(baseURL: URL(string: "https://test.local")!, transport: transport)
        try await api.separateSource(showID: 7, sourceID: 9)
        #expect(transport.lastRequest?.url?.path == "/feeds/7/sources/9")
        #expect(transport.lastRequest?.httpMethod == "DELETE")
    }

    @Test func olderShowPayloadsStillDecode() async throws {
        let json = """
            [{"id":7,"title":"Publication","description":null,"image_url":null,"episode_count":2}]
            """
        let api = HearfulAPI(baseURL: URL(string: "https://test.local")!, transport: FakeTransport(json: json))
        let shows = try await api.shows()
        #expect(shows[0].sources == nil)
    }

    @Test func groupedShowPayloadsDecode() async throws {
        let json = """
            [{"id":7,"title":"Publication","description":null,"image_url":null,"episode_count":2,
              "sources":\(sourceJSON)}]
            """
        let api = HearfulAPI(baseURL: URL(string: "https://test.local")!, transport: FakeTransport(json: json))
        let shows = try await api.shows()
        #expect(shows[0].sources?.first?.id == 7)
    }

    enum Change: CaseIterable { case combine, separate }

    @MainActor @Test(arguments: Change.allCases)
    func acceptedChangeSurvivesRefreshFailureAndRetry(_ change: Change) async throws {
        let separating = change == .separate
        let transport = SourceGroupTransport(grouped: separating)
        let api = HearfulAPI(baseURL: URL(string: "https://example.invalid")!, transport: transport)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let followingAPI = HearfulAPI(baseURL: URL(string: "https://following.invalid")!, transport: transport)
        let following = LibraryModel(api: followingAPI, cache: OfflineCache(directory: directory))
        await following.load()
        let notifications = NotificationCenter()
        var followingRefresh: Task<Void, Never>?
        let observer = notifications.publisher(for: .hearfulSubscriptionsChanged).sink { _ in
            followingRefresh = Task { await following.subscriptionsChanged() }
        }
        defer { observer.cancel() }
        var announcements: [String] = []
        let sheet = FeedSourcesModel(api: api, notifications: notifications, announce: { announcements.append($0) })
        await sheet.load(showID: 7)
        let oldShows = separating ? [7] : [7, 9]
        let newShows = separating ? [7, 9] : [7]
        let oldSources = separating ? [7, 9] : [7]
        let newSources = separating ? [7] : [7, 9]
        #expect(following.availableShows.map(\.id) == oldShows)
        if separating {
            await sheet.separate(try #require(sheet.sources.first { $0.id == 9 }), from: 7)
        } else {
            await sheet.combine(try #require(sheet.available.first { $0.id == 9 }), into: 7)
        }
        try await #require(followingRefresh).value
        #expect(following.needsRetry && following.availableShows.map(\.id) == oldShows)
        #expect(sheet.needsSourceRefresh && sheet.sources.map(\.id) == oldSources)
        let success = separating ? "Source separated." : "Sources combined."
        let message = "\(success) The source list couldn’t be refreshed. Tap Try again to refresh Manage Sources and Following."
        #expect(sheet.error == message)
        #expect(announcements == [message])

        // A second failed read must still explain that the write already succeeded.
        await transport.holdNextFollowingFailure()
        followingRefresh = nil
        await sheet.retry(showID: 7)
        let slowRefresh = try #require(followingRefresh)
        let deadline = ContinuousClock.now + .seconds(5)
        while await !transport.followingIsWaiting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await transport.followingIsWaiting)
        #expect(sheet.error == message && sheet.needsSourceRefresh)
        #expect(announcements == [message, message])

        await transport.reconnect()
        followingRefresh = nil
        await sheet.retry(showID: 7)
        try await #require(followingRefresh).value
        // The successful retry must refresh Following even while its previous read is still pending.
        await transport.releaseFollowingFailure()
        await slowRefresh.value
        #expect(sheet.sources.map(\.id) == newSources)
        #expect(sheet.available.map(\.id) == newShows.filter { $0 != 7 })
        #expect(sheet.error == nil && !sheet.busy && !sheet.needsSourceRefresh)
        #expect(!following.needsRetry && following.availableShows.map(\.id) == newShows)
        #expect(announcements == [message, message])
        #expect(await transport.writes == [separating ? "DELETE" : "PUT"])
    }

    @MainActor @Test func failedLoadLeavesARecoverableError() async {
        let api = HearfulAPI(baseURL: URL(string: "https://test.local")!,
                             transport: FakeTransport(status: 503, json: "{}"))
        let model = FeedSourcesModel(api: api)
        await model.load(showID: 7)
        #expect(!model.busy)
        #expect(model.error != nil)
        #expect(model.sources.isEmpty)
    }
}

/// The write reaches the server, then both Following and Manage Sources lose connectivity.
private actor SourceGroupTransport: DataTransport {
    private var grouped: Bool
    private var offline = false
    private(set) var writes: [String] = []
    private var holdFailure = false
    private var waiting: CheckedContinuation<Void, Never>?
    var followingIsWaiting: Bool { waiting != nil }
    func holdNextFollowingFailure() { holdFailure = true }
    func releaseFollowingFailure() { waiting?.resume(); waiting = nil }

    init(grouped: Bool) { self.grouped = grouped }
    func reconnect() { offline = false }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let method = try #require(request.httpMethod)
        let json: String
        switch (method, url.path) {
        case ("PUT", "/feeds/7/sources/9"), ("DELETE", "/feeds/7/sources/9"):
            writes.append(method)
            grouped = method == "PUT"
            offline = true
            json = ""
        case ("GET", "/feeds"):
            if offline {
                if holdFailure && url.host == "following.invalid" {
                    holdFailure = false
                    await withCheckedContinuation { waiting = $0 }
                }
                throw URLError(.notConnectedToInternet)
            }
            let main = #"{"id":7,"title":"Main","episode_count":2}"#
            let second = #"{"id":9,"title":"Second","episode_count":1}"#
            json = "[" + (grouped ? [main] : [main, second]).joined(separator: ",") + "]"
        case ("GET", "/feeds/7/sources"):
            if offline { throw URLError(.notConnectedToInternet) }
            let main = #"{"id":7,"title":"Main","url":"https://main.invalid","source":"rss","is_primary":true,"is_failing":false}"#
            let second = #"{"id":9,"title":"Second","url":"https://second.invalid","source":"rss","is_primary":false,"is_failing":false}"#
            json = "[" + (grouped ? [main, second] : [main]).joined(separator: ",") + "]"
        default:
            throw URLError(.badURL)
        }
        let response = HTTPURLResponse(url: url, statusCode: method == "GET" ? 200 : 204, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }
}
