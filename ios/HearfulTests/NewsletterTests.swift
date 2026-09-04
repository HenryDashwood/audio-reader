import Foundation
import Testing

@testable import Hearful

private func makeClient(_ transport: DataTransport) -> HearfulAPI {
    HearfulAPI(baseURL: URL(string: "http://test.local")!, transport: transport)
}

@Suite("Newsletter address")
struct NewsletterAddressTests {
    @Test func decodes() async throws {
        let transport = FakeTransport(json: #"{"address":"nwxtemygmy@magpieinbox.com"}"#)

        let address = try await makeClient(transport).newsletterAddress()

        #expect(address.address == "nwxtemygmy@magpieinbox.com")
        #expect(transport.lastRequest?.url?.path == "/newsletters/address")
    }

    @Test func saysTheWordsAndTheDomainAsWords() {
        let address = NewsletterAddress(address: "quiet-heron-otter@magpieinbox.com")

        #expect(address.localPart == "quiet-heron-otter")
        #expect(address.domain == "magpieinbox.com")
        #expect(address.words == ["quiet", "heron", "otter"])
        #expect(
            address.spoken
                == "quiet, heron, otter, with hyphens between the words, at magpieinbox dot com")
    }

    @Test func spellsEveryLetterIncludingTheHyphens() {
        let address = NewsletterAddress(address: "ox-elk@magpieinbox.com")

        #expect(address.spelledOut == "o, x, hyphen, e, l, k, at magpieinbox dot com")
    }

    @Test func anOlderRandomAddressIsSpelledRatherThanSaid() {
        let address = NewsletterAddress(address: "nwxtemygmy@magpieinbox.com")

        #expect(address.words == nil)
        #expect(address.spoken == "n, w, x, t, e, m, y, g, m, y, at magpieinbox dot com")
    }
}

@Suite("Pending newsletters")
struct PendingNewsletterTests {
    private let pendingJSON = """
        [{"id": 7, "title": "Matt Levine", "sender_address": "noreply@news.bloomberg.com",
          "message_count": 2, "latest_title": "Money Stuff: Things Happen",
          "latest_at": "2026-09-01T18:14:03Z"},
         {"id": 8, "title": "Benedict Evans", "sender_address": "list@ben-evans.com",
          "message_count": 1}]
        """

    @Test func decodesTheList() async throws {
        let transport = FakeTransport(json: pendingJSON)

        let pending = try await makeClient(transport).pendingNewsletters()

        #expect(pending.map(\.id) == [7, 8])
        #expect(pending[0].title == "Matt Levine")
        #expect(pending[0].senderAddress == "noreply@news.bloomberg.com")
        #expect(pending[0].messageCountLabel == "2 messages")
        #expect(pending[0].latestTitle == "Money Stuff: Things Happen")
        #expect(pending[0].latestAt != nil)
        #expect(pending[1].messageCountLabel == "1 message")
        #expect(pending[1].latestTitle == nil)
        #expect(transport.lastRequest?.url?.path == "/newsletters/pending")
    }

    @Test func approvingPostsAndReturnsTheShow() async throws {
        let json = """
            {"id": 7, "url": "email://u/x", "title": "Matt Levine", "description": null,
             "image_url": null, "episode_count": 2, "is_article_feed": true, "source": "email"}
            """
        let transport = FakeTransport(json: json)

        let show = try await makeClient(transport).approveNewsletter(id: 7)

        #expect(transport.lastRequest?.httpMethod == "POST")
        #expect(transport.lastRequest?.url?.path == "/newsletters/7/approve")
        #expect(show.isNewsletter)
        #expect(show.itemCountLabel == "2 issues")
        #expect(show.itemsSectionTitle == "Issues")
    }

    @Test func blockingPosts() async throws {
        let transport = FakeTransport(status: 204, json: "")

        try await makeClient(transport).blockNewsletter(id: 7)

        #expect(transport.lastRequest?.httpMethod == "POST")
        #expect(transport.lastRequest?.url?.path == "/newsletters/7/block")
    }

    @Test func ordinaryShowsAreNotNewsletters() {
        let show = Show(
            id: 1, title: "In Our Time", description: nil, artworkURL: nil, episodeCount: 3)

        #expect(!show.isNewsletter)
        #expect(show.itemNoun == "episode")
    }
}

/// Whether a notification arrived. A class so the observer closure, which
/// the compiler rightly treats as concurrent, has something it may mutate;
/// nonisolated because the project's default isolation is the main actor,
/// and that closure is not on it as far as the compiler knows.
private nonisolated final class Seen: @unchecked Sendable {
    var value = false
}

/// Just enough of the API for the pending list: the calls it makes are
/// recorded, and every other method is unreachable.
private final class NewsletterAPI: HearfulAPIProtocol, @unchecked Sendable {
    var pending: [PendingNewsletter]
    var failApprove = false
    private(set) var approved: [Int] = []
    private(set) var blocked: [Int] = []

    init(pending: [PendingNewsletter]) {
        self.pending = pending
    }

    func pendingNewsletters() async throws -> [PendingNewsletter] { pending }

    func approveNewsletter(id: Int) async throws -> Show {
        if failApprove {
            throw APIError(spokenResponse: "That newsletter is no longer waiting.", underlying: "HTTP 404")
        }
        approved.append(id)
        return Show(
            id: id, title: "Matt Levine", description: nil, artworkURL: nil, episodeCount: 2,
            isArticleFeed: true, isFailing: false, source: "email")
    }

    func blockNewsletter(id: Int) async throws { blocked.append(id) }

    func command(
        transcript: String, nowPlayingEpisodeID: Int?, turns: [ConversationTurn], traceparent: String?
    ) async throws -> CommandResponse { fatalError("not used") }
    func episode(id: Int) async throws -> Episode { fatalError("not used") }
    func articleText(episodeID: Int) async throws -> EpisodeText { fatalError("not used") }
    func recentEpisodes(limit: Int) async throws -> [Episode] { [] }
    func shows() async throws -> [Show] { [] }
    func episodes(showID: Int, query: String?) async throws -> [Episode] { [] }
    func searchPodcasts(query: String) async throws -> [PodcastResult] { [] }
    func previewFeed(url: URL) async throws -> FeedPreview { fatalError("not used") }
    func subscribe(feedURL: URL) async throws -> Show { fatalError("not used") }
    func unsubscribe(showID: Int) async throws {}
    func login(appleIdentityToken: String, authorizationCode: String?) async throws -> AuthResponse {
        fatalError("not used")
    }
    func logout() async throws {}
    func me() async throws -> UserInfo { UserInfo(id: "u1", displayName: nil) }
    func deleteAccount() async throws {}
    func reportPosition(
        episodeID: Int, seconds: Double, completed: Bool, durationSeconds: Int?
    ) async throws {}
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws {}
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String?) async throws {}
    func reportDiagnostic(_ event: [String: any Sendable]) async throws {}
}

@Suite("Pending newsletters model")
@MainActor
struct PendingNewslettersModelTests {
    private let levine = PendingNewsletter(
        id: 7, title: "Matt Levine", senderAddress: "noreply@news.bloomberg.com", messageCount: 2,
        latestTitle: "Money Stuff: Things Happen", latestAt: nil)
    private let evans = PendingNewsletter(
        id: 8, title: "Benedict Evans", senderAddress: "list@ben-evans.com", messageCount: 1)

    @Test func loadsTheList() async {
        let model = PendingNewslettersModel(api: NewsletterAPI(pending: [levine, evans]))

        await model.load()

        #expect(model.pending.map(\.id) == [7, 8])
    }

    @Test func followingRemovesTheSenderAndTellsTheLibrary() async {
        let api = NewsletterAPI(pending: [levine, evans])
        let model = PendingNewslettersModel(api: api)
        await model.load()
        let notified = Seen()
        let observer = NotificationCenter.default.addObserver(
            forName: .hearfulSubscriptionsChanged, object: nil, queue: nil
        ) { _ in notified.value = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        let followed = await model.approve(levine)

        #expect(followed)
        #expect(api.approved == [7])
        #expect(model.pending.map(\.id) == [8])
        #expect(notified.value)
        #expect(model.errorMessage == nil)
    }

    @Test func blockingRemovesTheSender() async {
        let api = NewsletterAPI(pending: [levine, evans])
        let model = PendingNewslettersModel(api: api)
        await model.load()

        let blocked = await model.block(evans)

        #expect(blocked)
        #expect(api.blocked == [8])
        #expect(model.pending.map(\.id) == [7])
    }

    @Test func aFailureIsSpokenAndLeavesTheRowInPlace() async {
        let api = NewsletterAPI(pending: [levine])
        api.failApprove = true
        let model = PendingNewslettersModel(api: api)
        await model.load()

        let followed = await model.approve(levine)

        #expect(!followed)
        #expect(model.pending.map(\.id) == [7])
        #expect(model.errorMessage == "That newsletter is no longer waiting.")
    }
}

@Suite("Newsletter signup")
struct NewsletterSignupTests {
    @Test func decodesASubmittedSignup() async throws {
        let json = """
            {"status": "submitted", "publication": "Understanding AI", "platform": "substack",
             "address": "hefty-prism-bolt@magpieinbox.com", "reason": null,
             "spoken_response": "I have asked Understanding AI to send its newsletter to your address."}
            """
        let transport = FakeTransport(json: json)

        let signup = try await makeClient(transport).signUpForNewsletter(url: URL(string: "https://www.understandingai.org")!)

        #expect(signup.submitted)
        #expect(signup.publication == "Understanding AI")
        #expect(transport.lastRequest?.httpMethod == "POST")
        #expect(transport.lastRequest?.url?.path == "/newsletters/signups")
        // Foundation escapes slashes when it encodes a URL, so compare the
        // decoded value rather than the bytes.
        let body = try JSONDecoder().decode([String: String].self, from: transport.lastRequest?.httpBody ?? Data())
        #expect(body["url"] == "https://www.understandingai.org")
    }

    @Test func decodesTheManualPath() async throws {
        let json = """
            {"status": "unsupported", "reason": "account_required", "address": "hefty-prism-bolt@magpieinbox.com",
             "spoken_response": "bloomberg.com needs an account before it will send its newsletter."}
            """

        let signup = try await makeClient(FakeTransport(json: json)).signUpForNewsletter(url: URL(string: "https://bloomberg.com")!)

        #expect(!signup.submitted)
        #expect(signup.reason == "account_required")
        #expect(signup.address == "hefty-prism-bolt@magpieinbox.com")
    }
}
