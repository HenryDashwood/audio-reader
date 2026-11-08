import SwiftUI
import Testing

@testable import Hearful

/// Records search queries; every other method is unused here.
private final class SearchAPI: HearfulAPIProtocol, @unchecked Sendable {
    var reportedAttempts: [[String: any Sendable]] = []
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String? = nil) async throws {
        reportedAttempts.append(event)
    }

    func reportDiagnostic(_ event: [String: any Sendable]) async throws {}

    var results: [PodcastResult] = []
    var episodeResults: [Episode] = []
    var delayedWebResult: (@Sendable () async throws -> PodcastResult?)?
    var webResult: PodcastResult?
    var delayedDiscovery: (@Sendable () async throws -> FeedDiscoveryResponse)?
    var signupReply: (@Sendable () async throws -> NewsletterSignup)?
    private(set) var signupURLs: [URL] = []
    var discoveryResponse: FeedDiscoveryResponse?
    var error: Error?
    private(set) var queries: [String] = []
    private(set) var episodeQueries: [String] = []
    private(set) var webQueries: [String] = []
    private(set) var discoveryURLs: [URL] = []

    func searchPodcasts(query: String) async throws -> [PodcastResult] {
        queries.append(query)
        if let error { throw error }
        return results
    }

    func searchLibraryEpisodes(query: String) async throws -> [Episode] {
        episodeQueries.append(query)
        if let error { throw error }
        return episodeResults
    }

    func searchPublicationOnWeb(query: String) async throws -> PodcastResult? {
        webQueries.append(query)
        if let delayedWebResult { return try await delayedWebResult() }
        if let error { throw error }
        return webResult
    }

    func discoverFeeds(url: URL) async throws -> FeedDiscoveryResponse {
        discoveryURLs.append(url)
        if let delayedDiscovery { return try await delayedDiscovery() }
        if let error { throw error }
        guard let discoveryResponse else { throw APIError(underlying: "no discovery response") }
        return discoveryResponse
    }

    func signUpForNewsletter(url: URL) async throws -> NewsletterSignup {
        signupURLs.append(url)
        let reply = try #require(signupReply)
        return try await reply()
    }

    func command(
        transcript: String, nowPlayingEpisodeID: Int? = nil, turns: [ConversationTurn] = [],
        traceparent: String? = nil
    ) async throws
        -> CommandResponse {
        CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)
    }
    func episode(id: Int) async throws -> Episode { throw APIError(underlying: "unused") }
    func articleText(episodeID: Int) async throws -> EpisodeText {
        throw APIError(underlying: "unused")
    }
    func recentEpisodes(limit: Int) async throws -> [Episode] { [] }
    func shows() async throws -> [Show] { [] }
    func episodes(showID: Int, query: String? = nil) async throws -> [Episode] { [] }
    func login(appleIdentityToken: String, authorizationCode: String?) async throws
        -> AuthResponse
    {
        AuthResponse(token: "t", user: UserInfo(id: "u", displayName: nil))
    }
    func logout() async throws {}
    func deleteAccount() async throws {}
    func me() async throws -> UserInfo { UserInfo(id: "u", displayName: nil) }
    func reportPosition(
        episodeID: Int, seconds: Double, completed: Bool, durationSeconds: Int?
    ) async throws {}
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws {}
    func previewFeed(url: URL) async throws -> FeedPreview { throw APIError(underlying: "unused") }
    func subscribe(feedURL: URL) async throws -> Show { throw APIError(underlying: "unused") }
    func unsubscribe(showID: Int) async throws {}
}

private func discoveredFeed(_ title: String, primary: Bool = true) -> FeedDiscoveryCandidate {
    FeedDiscoveryCandidate(
        title: title,
        feedURL: URL(string: "https://feeds.example.com/\(title.lowercased())")!,
        description: nil,
        siteURL: URL(string: "https://example.com"),
        format: "rss",
        itemCount: 10,
        audioItemCount: 0,
        recentItemTitles: ["Newest"],
        source: "html",
        isPrimary: primary)
}

private func result(_ title: String) -> PodcastResult {
    PodcastResult(
        title: title, feedURL: URL(string: "https://feeds.example.com/x")!,
        publisher: nil, episodeCount: nil, artworkURL: nil)
}

/// Waits for the debounce window plus the request to settle.
@MainActor
private func settle() async {
    try? await Task.sleep(for: .milliseconds(120))
}

/// Polls until the state leaves .searching: a fixed sleep is flaky when the
/// test host is under load.
@MainActor
private func settleUntilDone(_ model: PodcastSearchModel) async {
    for _ in 0..<200 {
        switch model.state {
        case .idle, .searching:
            try? await Task.sleep(for: .milliseconds(10))
        case .loaded, .failed:
            return
        }
    }
}

@MainActor
@Suite("Podcast search model")
struct PodcastSearchModelTests {
    private func makeModel(_ api: SearchAPI) -> PodcastSearchModel {
        PodcastSearchModel(api: api, debounce: .milliseconds(40))
    }

    @Test func typingBurstBecomesOneRequest() async {
        let api = SearchAPI()
        api.results = [result("The Rest Is History")]
        let model = makeModel(api)

        model.queryChanged("r")
        model.queryChanged("re")
        model.queryChanged("rest is history")
        await settleUntilDone(model)

        #expect(api.queries == ["rest is history"])
        #expect(api.episodeQueries == ["rest is history"])
        #expect(model.state == .loaded)
        #expect(model.podcasts == [result("The Rest Is History")])
    }

    @Test func searchNowSkipsTheDebounce() async {
        let api = SearchAPI()
        let model = makeModel(api)

        model.searchNow(for: "in our time")
        await settleUntilDone(model)

        #expect(api.queries == ["in our time"])
    }

    @Test func clearingAbandonsThePendingSearch() async {
        let api = SearchAPI()
        let model = makeModel(api)

        model.queryChanged("rest")
        model.clear()
        await settle()

        #expect(api.queries.isEmpty)
        #expect(model.state == .idle)
    }

    @Test func emptyQueryReturnsToIdleWithoutSearching() async {
        let api = SearchAPI()
        let model = makeModel(api)

        model.queryChanged("rest")
        model.queryChanged("")
        await settle()

        #expect(api.queries.isEmpty)
        #expect(model.state == .idle)
    }

    @Test func failureIsSpeakable() async {
        let api = SearchAPI()
        api.error = APIError(
            spokenResponse: "I cannot reach the internet right now.", underlying: "offline")
        let model = makeModel(api)

        model.searchNow(for: "rest")
        await settleUntilDone(model)

        #expect(model.state == .failed("I cannot reach the internet right now."))
    }

    @Test func libraryEpisodesAndDirectoryResultsAreKeptSeparately() async {
        let api = SearchAPI()
        api.results = [result("The Rest Is History")]
        api.episodeResults = [episode("Agincourt")]
        let model = makeModel(api)

        model.searchNow(for: "agincourt")
        await settleUntilDone(model)

        #expect(model.podcasts.map(\.title) == ["The Rest Is History"])
        #expect(model.episodes.map(\.title) == ["Agincourt"])
    }

    @Test func explicitWebSearchIsNeverTriggeredByTyping() async {
        let api = SearchAPI()
        api.webResult = result("Notes on Progress")
        let model = makeModel(api)

        model.searchNow(for: "notes on progress")
        await settleUntilDone(model)
        #expect(api.webQueries.isEmpty)

        model.searchWebNow(for: "notes on progress")
        for _ in 0..<100 where model.isSearchingWeb {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(api.webQueries == ["notes on progress"])
        #expect(model.webPublication?.title == "Notes on Progress")
    }
}

private actor DelayedWebResult {
    var reply: CheckedContinuation<PodcastResult?, any Error>?

    func search() async throws -> PodcastResult? {
        try await withCheckedThrowingContinuation { reply = $0 }
    }

    func finish(with result: Result<PodcastResult?, any Error>) {
        reply?.resume(with: result)
        reply = nil
    }
}

@MainActor
private final class SourceSheetPresentation: ObservableObject {
    @Published var showing = false
    var model: PodcastSearchModel
    init(model: PodcastSearchModel) { self.model = model }
}

private struct SourceSheetHost: View {
    @StateObject private var auth = AuthController(notificationCenter: NotificationCenter(), readToken: { nil })
    @ObservedObject var presentation: SourceSheetPresentation

    var body: some View {
        Text("Following").sheet(isPresented: $presentation.showing) {
            AddSourcesView(shows: [], searchModel: presentation.model)
                .environmentObject(auth)
        }
    }
}

@MainActor
struct AddSourcesDismissalTests {
    enum Destination: CaseIterable { case following, reopened }
    enum Response: CaseIterable { case match, failure }

    private func waitFor(_ description: String, _ ready: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await ready(), "Timed out waiting for \(description)")
    }

    @Test(.serialized, arguments: Destination.allCases, Response.allCases)
    func webSearchFinishesAfterDismissal(_ destination: Destination, _ response: Response) async throws {
        let gate = DelayedWebResult()
        let api = SearchAPI()
        api.delayedWebResult = { try await gate.search() }
        var announcements: [String] = []
        let first = PodcastSearchModel(api: api, announce: { announcements.append($0) })
        let presentation = SourceSheetPresentation(model: first)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: SourceSheetHost(presentation: presentation))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        func openSheet() async throws {
            presentation.showing = true
            try await waitFor("Add Sources to appear") {
                host.presentedViewController?.viewIfLoaded?.window === window &&
                    host.presentedViewController?.isBeingPresented == false
            }
        }

        try await openSheet()
        first.searchWebNow(for: "Alpha")
        let pending = try #require(first.webPending)
        try await waitFor("Alpha request") { await gate.reply != nil }
        presentation.showing = false
        try await waitFor("Following") { host.presentedViewController == nil }

        if destination == .reopened {
            let secondAPI = SearchAPI()
            secondAPI.webResult = result("Publication Beta")
            let second = PodcastSearchModel(api: secondAPI, announce: { announcements.append($0) })
            presentation.model = second
            try await openSheet()
            second.searchWebNow(for: "Beta")
            await second.webPending?.value
        }

        switch response {
        case .match: await gate.finish(with: .success(result("Publication Alpha")))
        case .failure: await gate.finish(with: .failure(APIError(spokenResponse: "Alpha failed", underlying: "offline")))
        }
        await pending.value
        #expect(first.webPublication == nil && first.webMessage == nil)
        if destination == .reopened {
            #expect(presentation.model.webPublication == result("Publication Beta"))
            #expect(presentation.model.webMessage == nil && !presentation.model.isSearchingWeb)
            #expect(announcements == ["Found Publication Beta on the web"])
        } else {
            #expect(announcements.isEmpty)
        }
    }
}

@MainActor
@Suite("Feed discovery model")
struct FeedDiscoveryModelTests {
    enum OldReply: CaseIterable { case feeds, discoveryError, signupSuccess, signupError }

    @Test(arguments: OldReply.allCases, [false, true])
    func closedLookupOrSignupCannotAnnounceOrReplaceAnotherSite(reply: OldReply, reopen: Bool) async throws {
        let signup = reply == .signupSuccess || reply == .signupError
        let fails = reply == .discoveryError || reply == .signupError
        let api = SearchAPI()
        let first = URL(string: "https://first.invalid")!
        let second = URL(string: "https://second.invalid")!
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var announcements: [String] = []
        let model = FeedDiscoveryModel(api: api) { announcements.append($0) }
        api.discoveryResponse = FeedDiscoveryResponse(submittedURL: first, candidates: [])
        await model.load(url: first)
        let original = try #require(model.visit)
        let oldResponse = FeedDiscoveryResponse(submittedURL: first, candidates: [discoveredFeed("First")])
        @Sendable func waitForReply() async throws {
            started.continuation.finish()
            for await _ in release.stream {}
            if fails { throw APIError(spokenResponse: "Old error", underlying: "fixture") }
        }
        api.delayedDiscovery = { try await waitForReply(); return oldResponse }
        api.signupReply = { try await waitForReply(); return NewsletterSignup(status: "submitted", spokenResponse: "Old signup") }
        let pending = Task {
            if signup { await model.signUp(for: original) }
            else { await model.retry(for: original) }
        }
        for await _ in started.stream {}
        model.close()
        api.delayedDiscovery = nil
        let candidates = [discoveredFeed("Second")]
        if reopen {
            api.discoveryResponse = FeedDiscoveryResponse(submittedURL: second, candidates: candidates)
            await model.load(url: second)
        }
        await model.signUp(for: original)
        release.continuation.finish()
        await pending.value
        #expect(model.state == (reopen ? .loaded(candidates) : .loading))
        #expect(announcements == (reopen ? ["One feed found"] : []))
        #expect(api.signupURLs == (signup ? [first] : []))
    }

    @Test func oldSignupAndRapidTapsCannotInterruptOrDuplicateTheCurrentSignup() async throws {
        let api = SearchAPI()
        var announcements: [String] = []
        let model = FeedDiscoveryModel(api: api) { announcements.append($0) }
        let first = URL(string: "https://first.invalid")!
        let second = URL(string: "https://second.invalid")!
        api.discoveryResponse = FeedDiscoveryResponse(submittedURL: first, candidates: [])
        let firstStarted = AsyncStream<Void>.makeStream()
        let firstRelease = AsyncStream<Void>.makeStream()
        api.signupReply = {
            firstStarted.continuation.finish()
            for await _ in firstRelease.stream {}
            throw APIError(spokenResponse: "Old error", underlying: "fixture")
        }
        await model.load(url: first)
        let firstVisit = try #require(model.visit)
        let original = Task { await model.signUp(for: firstVisit) }
        for await _ in firstStarted.stream {}
        model.close()
        let secondStarted = AsyncStream<Void>.makeStream()
        let secondRelease = AsyncStream<Void>.makeStream()
        let result = NewsletterSignup(status: "submitted", spokenResponse: "Signup sent for the second site")
        api.signupReply = {
            secondStarted.continuation.finish()
            for await _ in secondRelease.stream {}
            return result
        }
        api.discoveryResponse = FeedDiscoveryResponse(submittedURL: second, candidates: [])
        await model.load(url: second)
        let secondVisit = try #require(model.visit)
        let replacement = Task { await model.signUp(for: secondVisit) }
        for await _ in secondStarted.stream {}
        firstRelease.continuation.finish()
        await original.value
        #expect(model.signingUp)
        await model.retry(for: secondVisit)
        await model.signUp(for: secondVisit)
        secondRelease.continuation.finish()
        await replacement.value
        #expect(api.discoveryURLs == [first, second])
        #expect(api.signupURLs == [first, second])
        #expect(model.state == .signedUp(result))
        #expect(!model.signingUp)
        #expect(announcements == [result.spokenResponse])
    }

    @Test func oldSignupButtonCannotUseTheReplacementAccountBeforeItsPageReloads() async throws {
        let api = SearchAPI()
        let url = URL(string: "https://publisher.invalid")!
        api.discoveryResponse = FeedDiscoveryResponse(submittedURL: url, candidates: [])
        api.signupReply = { NewsletterSignup(status: "submitted", spokenResponse: "Sent") }
        var announcements: [String] = []
        let model = FeedDiscoveryModel(api: api) { announcements.append($0) }
        await HearfulAPI.$tokenProvider.withValue({ "first-token" }) { await model.load(url: url) }
        let old = try #require(model.visit)
        try await HearfulAPI.$tokenProvider.withValue({ "second-token" }) {
            await model.signUp(for: old)
            #expect(api.signupURLs.isEmpty)
            #expect(announcements.isEmpty)
            await model.load(url: url)
            let current = try #require(model.visit)
            await model.signUp(for: current)
            #expect(api.signupURLs == [url])
            #expect(announcements == ["Sent"])
        }
    }

    @Test func keepsEveryRankedCandidateForVisualSelection() async {
        let api = SearchAPI()
        let url = URL(string: "https://example.com")!
        api.discoveryResponse = FeedDiscoveryResponse(
            submittedURL: url,
            candidates: [
                discoveredFeed("Main articles"),
                discoveredFeed("Comments", primary: false),
            ])
        let model = FeedDiscoveryModel(api: api)

        await model.load(url: url)

        #expect(
            model.state
                == .loaded([
                    discoveredFeed("Main articles"),
                    discoveredFeed("Comments", primary: false),
                ]))
        #expect(api.discoveryURLs == [url])
    }

    @Test func failureUsesTheBackendSentence() async {
        let api = SearchAPI()
        api.error = APIError(
            spokenResponse: "Magpie reached that site, but found no feed.",
            underlying: "no_feed_found")
        let model = FeedDiscoveryModel(api: api)

        await model.load(url: URL(string: "https://example.com")!)

        #expect(model.state == .failed("Magpie reached that site, but found no feed."))
    }
}

private func episode(_ title: String) -> Episode {
    Episode(
        id: 1,
        title: title,
        description: nil,
        author: nil,
        feedTitle: "History Show",
        audioURL: URL(string: "https://cdn.example.com/1.mp3"),
        durationSeconds: nil,
        publishedAt: nil,
        link: nil,
        imageURL: nil,
        positionSeconds: nil,
        completed: nil,
        dismissed: nil,
        hasText: nil)
}

@Suite("Local show search")
struct LocalShowSearchTests {
    private let shows = [
        Show(
            id: 1,
            title: "The Rest Is History",
            description: "World history",
            artworkURL: nil,
            episodeCount: 10,
            isArticleFeed: false,
            isFailing: false),
        Show(
            id: 2,
            title: "Café Europa",
            description: "Politics from the continent",
            artworkURL: nil,
            episodeCount: 5,
            isArticleFeed: false,
            isFailing: false),
    ]

    @Test func aTranspositionStillFindsTheShow() {
        #expect(showsMatching(shows, query: "hsitory").map(\.id) == [1])
    }

    @Test func accentsAndDescriptionsAreSearchable() {
        #expect(showsMatching(shows, query: "cafe").map(\.id) == [2])
        #expect(showsMatching(shows, query: "politics continent").map(\.id) == [2])
    }

    @Test func followingFiltersFromTheFirstCharacterAndUpdatesAsYouType() {
        for query in ["h", "hi", "his", "hist", "histo", "histor", "history"] {
            #expect(followedShowsMatching(shows, query: query).map(\.id) == [1])
        }
        #expect(followedShowsMatching(shows, query: "historyx").isEmpty)
        #expect(followedShowsMatching(shows, query: "c").map(\.id) == [2])
    }

    @Test func followingMatchesFeedNamesIgnoringCaseAndAccents() {
        #expect(followedShowsMatching(shows, query: "CAFÉ").map(\.id) == [2])
        #expect(followedShowsMatching(shows, query: " cafe ").map(\.id) == [2])
        #expect(followedShowsMatching(shows, query: "uropa").map(\.id) == [2])
        #expect(followedShowsMatching(shows, query: "continent").isEmpty)
    }

    @Test func clearingFollowingSearchRestoresEveryFeedInOrder() {
        for query in ["", " \n "] {
            #expect(followedShowsMatching(shows, query: query).map(\.id) == [1, 2])
        }
        #expect(followedShowsMatching([], query: "h").isEmpty)
    }
}

@Suite struct DirectorySearchResultsTests {
    private func found(
        _ title: String, url: String, kind: String? = nil
    ) -> PodcastResult {
        PodcastResult(
            title: title, feedURL: URL(string: url)!, publisher: nil, episodeCount: nil,
            artworkURL: nil, kind: kind)
    }

    private let followed = Show(
        id: 1, title: "The Rest Is History", description: nil, artworkURL: nil, episodeCount: 10)

    @Test func looseDirectoryMatchesStillOfferTheWebSearch() {
        let results = directorySearchResults(
            query: "Construction physics", library: [],
            directory: [
                found("Creepy", url: "https://a.example/feed"),
                found("Constructive Interference", url: "https://b.example/feed"),
            ],
            web: nil)

        #expect(results.podcasts.count == 2)
        #expect(results.offersWebSearch)
    }

    @Test func aNamedPublicationIsListedFirstAndNeedsNoWebSearch() {
        let results = directorySearchResults(
            query: "constructoin physics", library: [],
            directory: [
                found(
                    "Construction Physics", url: "https://www.construction-physics.com/feed",
                    kind: "publication"),
                found("Creepy", url: "https://a.example/feed"),
            ],
            web: nil)

        #expect(results.publications.map(\.title) == ["Construction Physics"])
        #expect(results.podcasts.map(\.title) == ["Creepy"])
        #expect(results.publicationsFirst)
        #expect(!results.offersWebSearch)
    }

    @Test func eachFeedAppearsOnceWhateverFoundIt() {
        let results = directorySearchResults(
            query: "history", library: [followed],
            directory: [
                found("The Rest Is History", url: "https://rest.example/feed"),
                found("History Extra", url: "http://extra.example/feed"),
                found("History Extra", url: "https://extra.example/feed"),
            ],
            web: found("History Extra", url: "https://EXTRA.example/feed", kind: "publication"))

        #expect(results.podcasts.map(\.feedURL.absoluteString) == ["http://extra.example/feed"])
        #expect(results.web == nil)
    }
}
