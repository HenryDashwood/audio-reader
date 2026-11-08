import SwiftUI
import Testing
@testable import Hearful

private actor PodcastSubscriptionTransport: DataTransport {
    private var following: [String]
    private var pending: CheckedContinuation<Void, Never>?

    init(initiallyFollowing: Bool) {
        following = initiallyFollowing ? ["A", "B"] : []
    }

    let arrival = AsyncStream<Void>.makeStream()

    private func holdResponse() async {
        await withCheckedContinuation {
            pending = $0
            arrival.continuation.yield(())
            arrival.continuation.finish()
        }
    }

    func finishRequest() {
        pending?.resume()
        pending = nil
    }

    private func show(_ title: String) -> String {
        #"{"id":\#(title == "A" ? 1 : 2),"title":"\#(title)","episode_count":0}"#
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let json: String
        switch (request.httpMethod, url.path) {
        case ("GET", "/feeds"):
            json = "[" + following.map(show).joined(separator: ",") + "]"
        case ("POST", "/feeds/preview"):
            let body = try JSONDecoder().decode([String: URL].self, from: request.httpBody ?? Data())
            let title = try #require(body["url"]?.lastPathComponent)
            json = #"{"feed":\#(show(title)),"episodes":[],"subscribed":\#(following.contains(title))}"#
        case ("POST", "/feeds"):
            let body = try JSONDecoder().decode([String: URL].self, from: request.httpBody ?? Data())
            #expect(body["url"]?.lastPathComponent == "A")
            await holdResponse()
            following.append("A")
            json = show("A")
        case ("DELETE", "/feeds/1"):
            await holdResponse()
            following.removeAll { $0 == "A" }
            json = ""
        default:
            throw URLError(.badURL)
        }
        return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PodcastPreviewTests {
    enum Action: CaseIterable { case subscribe, unsubscribe }
    enum Destination: CaseIterable { case stayOnA, openB }

    @Test(arguments: Action.allCases, Destination.allCases)
    func subscriptionResult(_ action: Action, _ destination: Destination) async throws {
        let initiallyFollowing = action == .unsubscribe
        let transport = PodcastSubscriptionTransport(initiallyFollowing: initiallyFollowing)
        let server = URL(string: "https://example.invalid")!
        let api = HearfulAPI(baseURL: server, transport: transport)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let following = LibraryModel(api: api, cache: OfflineCache(directory: directory))
        await following.load()
        #expect(following.availableShows.map(\.title) == (initiallyFollowing ? ["A", "B"] : []))

        let notifications = NotificationCenter()
        var refresh: Task<Void, Never>?
        let observer = notifications.publisher(for: .hearfulSubscriptionsChanged).sink { _ in
            refresh = Task { await following.load() }
        }
        defer { observer.cancel() }

        var announcements: [String] = []
        func preview() -> PodcastPreviewModel {
            PodcastPreviewModel(api: api, notifications: notifications, announce: { announcements.append($0) })
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func open(_ title: String) async throws -> PodcastPreviewModel {
            let model = preview()
            let podcast = PodcastResult(title: title, feedURL: server.appending(path: title),
                                        publisher: nil, episodeCount: nil, artworkURL: nil)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                PodcastPreviewView(podcast: podcast, model: model)
            })
            window.isHidden = false
            for await state in model.$state.values {
                if case .loading = state { continue }
                break
            }
            try #require(model.isVisible)
            guard case .loaded = model.state else { throw URLError(.cannotLoadFromNetwork) }
            return model
        }
        let a = try await open("A")
        let urlA = server.appending(path: "A")
        #expect(a.subscribed == initiallyFollowing)
        let request = Task {
            switch action {
            case .subscribe: await a.subscribe(url: urlA, title: "A")
            case .unsubscribe: await a.unsubscribe(title: "A")
            }
        }
        for await _ in transport.arrival.stream { break }

        var b: PodcastPreviewModel?
        if destination == .openB {
            b = try await open("B")
            #expect(!a.isVisible)
            #expect(b?.subscribed == initiallyFollowing)
        }

        await transport.finishRequest()
        await request.value
        try await #require(refresh).value
        #expect(following.availableShows.map(\.title) == (initiallyFollowing ? ["B"] : ["A"]))
        #expect(a.subscribed != initiallyFollowing)
        if destination == .openB {
            let visible = try #require(b)
            #expect(visible.isVisible && visible.subscribed == initiallyFollowing)
            #expect(!visible.subscribing && visible.subscribeError == nil)
            #expect(announcements.isEmpty)
        } else {
            #expect(announcements == [initiallyFollowing ? "Unsubscribed from A" : "Subscribed to A"])
        }
    }
}
