import Foundation
import Testing

@testable import Hearful

/// A per-test transport, so parallel tests cannot tread on each other.
final class FakeTransport: DataTransport, @unchecked Sendable {
    private let result: Result<(Int, Data), Error>
    private(set) var lastRequest: URLRequest?

    init(status: Int = 200, json: String) {
        result = .success((status, Data(json.utf8)))
    }
    init(failure: Error) {
        result = .failure(failure)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        switch result {
        case .failure(let error):
            throw error
        case .success(let (status, data)):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }
}

private func makeClient(_ transport: DataTransport) -> HearfulAPI {
    HearfulAPI(baseURL: URL(string: "http://test.local")!, transport: transport)
}

private let playJSON = """
    {
      "action": "play_episode",
      "spoken_response": "Playing The Congress of Vienna.",
      "episode": {
        "id": 104,
        "title": "The Congress of Vienna",
        "description": "With guests Adam Zamoyski and Kate Williams.",
        "audio_url": "https://cdn.example.com/104.mp3",
        "duration_seconds": 2700,
        "published_at": "2026-08-04T00:00:00Z",
        "link": "https://example.com/104"
      }
    }
    """

@Suite("Command endpoint")
struct CommandEndpointTests {
    @Test func decodesPlayEpisode() async throws {
        let result = try await makeClient(FakeTransport(json: playJSON))
            .command(transcript: "play the Vienna one", nowPlayingEpisodeID: nil, traceparent: nil)

        #expect(result.action == .playEpisode)
        #expect(result.spokenResponse == "Playing The Congress of Vienna.")
        #expect(result.episode?.title == "The Congress of Vienna")
        #expect(result.episode?.audioURL?.absoluteString == "https://cdn.example.com/104.mp3")
        #expect(result.episode?.durationSeconds == 2700)
    }

    @Test func decodesPublishedDate() async throws {
        let result = try await makeClient(FakeTransport(json: playJSON)).command(transcript: "x", nowPlayingEpisodeID: nil, traceparent: nil)
        let expected = ISO8601DateFormatter().date(from: "2026-08-04T00:00:00Z")
        #expect(result.episode?.publishedAt == expected)
    }

    @Test func decodesFractionalSecondDates() async throws {
        // FastAPI emits fractional seconds for some rows; both forms must parse.
        let json = """
            {"action":"play_episode","spoken_response":"ok","episode":{
              "id":1,"title":"t","description":null,"audio_url":"https://x/y.mp3",
              "duration_seconds":null,"published_at":"2026-08-04T00:00:00.123456Z","link":null}}
            """
        let result = try await makeClient(FakeTransport(json: json)).command(transcript: "x", nowPlayingEpisodeID: nil, traceparent: nil)
        #expect(result.episode?.publishedAt != nil)
    }

    @Test func decodesUnknownWithNoEpisode() async throws {
        let json = """
            {"action":"unknown","spoken_response":"Which show would you like?","episode":null}
            """
        let result = try await makeClient(FakeTransport(json: json))
            .command(transcript: "play the thing", nowPlayingEpisodeID: nil, traceparent: nil)

        #expect(result.action == .unknown)
        #expect(result.episode == nil)
        #expect(result.spokenResponse == "Which show would you like?")
    }

    @Test func treatsUnrecognisedActionsAsUnknown() async throws {
        // The backend gains actions faster than the app can be reinstalled on
        // her phone; an unfamiliar one must degrade to "just say it", never
        // fail the whole request.
        let json = """
            {"action":"subscribed","spoken_response":"Subscribed to The Rest Is History.","episode":null}
            """
        let result = try await makeClient(FakeTransport(json: json)).command(transcript: "x", nowPlayingEpisodeID: nil, traceparent: nil)

        #expect(result.action == .unknown)
        #expect(result.spokenResponse == "Subscribed to The Rest Is History.")
    }

    @Test func sendsTranscriptAsJSONPost() async throws {
        let transport = FakeTransport(json: playJSON)
        _ = try await makeClient(transport).command(transcript: "play the Vienna one", nowPlayingEpisodeID: nil, traceparent: nil)

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/command")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody))
        #expect((body as? [String: Any])?["transcript"] as? String == "play the Vienna one")
        if let region = Locale.current.region?.identifier {
            #expect((body as? [String: Any])?["country"] as? String == region)
        }
    }

    @Test func sendsTheExchangeSoFar() async throws {
        // Her answer has to arrive with the question attached, or the backend
        // reads "the one about Agincourt" as a request out of nowhere.
        let transport = FakeTransport(json: playJSON)
        _ = try await makeClient(transport).command(
            transcript: "the one about Agincourt",
            turns: [
                ConversationTurn(speaker: .her, text: "play the rest is history"),
                ConversationTurn(speaker: .app, text: "Which episode?"),
            ])

        let body =
            try JSONSerialization.jsonObject(with: try #require(transport.lastRequest?.httpBody))
            as? [String: Any]
        #expect(
            body?["turns"] as? [[String: String]] == [
                ["speaker": "her", "text": "play the rest is history"],
                ["speaker": "app", "text": "Which episode?"],
            ])
    }

    @Test func sendsAnEmptyExchangeForAFreshRequest() async throws {
        let transport = FakeTransport(json: playJSON)
        _ = try await makeClient(transport).command(transcript: "play the latest")

        let body =
            try JSONSerialization.jsonObject(with: try #require(transport.lastRequest?.httpBody))
            as? [String: Any]
        #expect((body?["turns"] as? [Any])?.isEmpty == true)
    }

    @Test func decodesTheQuestionFlag() async throws {
        let json = """
            {"action":"unknown","spoken_response":"Which show did you mean?",
             "episode":null,"expects_reply":true}
            """
        let result = try await makeClient(FakeTransport(json: json)).command(transcript: "x")
        #expect(result.expectsReply == true)
    }

    @Test func aPayloadWithoutTheFlagStillDecodes() async throws {
        // An app newer than the backend it is talking to reads it as "no", and
        // behaves exactly as it did before any of this existed.
        let result = try await makeClient(FakeTransport(json: playJSON)).command(transcript: "x")
        #expect(result.expectsReply == nil)
    }
}

@Suite("Episode lookup")
struct EpisodeLookupTests {
    @Test func fetchesAnEpisodeByID() async throws {
        let json = """
            {"id":104,"title":"The Congress of Vienna","description":null,
             "audio_url":"https://cdn.example.com/104.mp3","duration_seconds":2700,
             "published_at":null,"link":null}
            """
        let transport = FakeTransport(json: json)
        let episode = try await makeClient(transport).episode(id: 104)

        #expect(episode.title == "The Congress of Vienna")
        #expect(transport.lastRequest?.url?.path == "/episodes/104")
    }

    @Test func missingEpisodeIsSpeakable() async {
        do {
            _ = try await makeClient(FakeTransport(status: 404, json: "{}")).episode(id: 9999)
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(!error.spokenResponse.isEmpty)
        } catch {
            Issue.record("wrong error type")
        }
    }
}

@Suite("Library")
struct LibraryTests {
    private let showsJSON = """
        [{"id":1,"url":"https://f/1","title":"In Our Time",
          "description":"Essential listening.","image_url":"https://img/1.jpg","episode_count":1102},
         {"id":2,"url":"https://f/2","title":"The Rest Is History",
          "description":null,"image_url":null,"episode_count":712}]
        """

    @Test func decodesSubscribedShows() async throws {
        let transport = FakeTransport(json: showsJSON)
        let shows = try await makeClient(transport).shows()

        #expect(shows.count == 2)
        #expect(shows[0].title == "In Our Time")
        #expect(shows[0].artworkURL?.absoluteString == "https://img/1.jpg")
        #expect(shows[0].episodeCount == 1102)
        #expect(transport.lastRequest?.url?.path == "/feeds")
    }

    @Test func toleratesShowsWithoutArtworkOrBlurb() async throws {
        let shows = try await makeClient(FakeTransport(json: showsJSON)).shows()
        #expect(shows[1].artworkURL == nil)
        #expect(shows[1].description == nil)
    }

    @Test func fetchesEpisodesForOneShow() async throws {
        let json = """
            [{"id":9,"title":"Seashells","description":"On molluscs.",
              "audio_url":"https://cdn/9.mp3","duration_seconds":3209,
              "published_at":"2026-07-30T08:02:00Z","link":null}]
            """
        let transport = FakeTransport(json: json)
        let episodes = try await makeClient(transport).episodes(showID: 1)

        #expect(episodes.first?.title == "Seashells")
        #expect(transport.lastRequest?.url?.path == "/feeds/1/episodes")
    }

    @Test func unreachableLibraryIsSpeakable() async {
        do {
            _ = try await makeClient(FakeTransport(failure: URLError(.timedOut))).shows()
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(!error.spokenResponse.isEmpty)
        } catch {
            Issue.record("wrong error type")
        }
    }
}

@Suite("Directory search and preview")
struct DirectorySearchTests {
    private let resultsJSON = """
        [{"title":"The Rest Is History","feed_url":"https://feeds.megaphone.fm/GLT4787413333",
          "publisher":"Goalhanger","episode_count":967,
          "artwork_url":"https://img.example.com/trih.jpg","itunes_id":123,
          "country":"GB","primary_genre":"History","latest_release_date":"2026-08-19T08:00:00Z"},
         {"title":"Sparse Show","feed_url":"https://feeds.example.com/sparse",
          "publisher":null,"episode_count":null,"artwork_url":null}]
        """

    @Test func searchSendsTheQuery() async throws {
        let transport = FakeTransport(json: resultsJSON)
        let results = try await makeClient(transport).searchPodcasts(query: "rest is history")

        #expect(results.count == 2)
        #expect(results[0].title == "The Rest Is History")
        #expect(results[0].publisher == "Goalhanger")
        #expect(results[0].artworkURL?.absoluteString == "https://img.example.com/trih.jpg")
        #expect(results[0].itunesID == 123)
        #expect(results[0].primaryGenre == "History")
        #expect(results[0].latestReleaseDate != nil)
        let url = try #require(transport.lastRequest?.url)
        #expect(url.path == "/search/podcasts")
        #expect(url.query?.contains("q=rest%20is%20history") == true)
        if let region = Locale.current.region?.identifier {
            #expect(url.query?.contains("country=\(region)") == true)
        }
    }

    @Test func toleratesResultsWithoutPublisherOrArtwork() async throws {
        let results = try await makeClient(FakeTransport(json: resultsJSON))
            .searchPodcasts(query: "x")
        #expect(results[1].publisher == nil)
        #expect(results[1].artworkURL == nil)
    }

    @Test func previewPostsTheFeedURL() async throws {
        let json = """
            {"feed":{"id":7,"url":"https://feeds.example.com/x","title":"The History Hour",
              "description":"A weekly podcast.","image_url":null,"episode_count":3},
             "episodes":[{"id":31,"title":"The Fall of Constantinople","description":null,
              "audio_url":"https://cdn.example.com/hh/103.mp3","duration_seconds":3723,
              "published_at":null,"link":null}],
             "subscribed":false}
            """
        let transport = FakeTransport(json: json)
        let preview = try await makeClient(transport)
            .previewFeed(url: URL(string: "https://feeds.example.com/x")!)

        #expect(preview.show.title == "The History Hour")
        #expect(preview.episodes.first?.audioURL != nil)
        #expect(preview.subscribed == false)
        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/feeds/preview")
        let body = try JSONDecoder().decode(
            [String: String].self, from: try #require(request.httpBody))
        #expect(body["url"] == "https://feeds.example.com/x")
    }

    @Test func discoveryDecodesRankedCandidatesAndPostsTheWebsite() async throws {
        let json = """
            {"submitted_url":"https://publication.example/","candidates":[
              {"title":"Main articles","feed_url":"https://publication.example/feed",
               "description":"All writing","site_url":"https://publication.example/",
               "format":"rss","item_count":42,"audio_item_count":0,
               "recent_item_titles":["The newest post"],"source":"html","is_primary":true},
              {"title":"Comments","feed_url":"https://publication.example/comments.xml",
               "description":null,"site_url":null,"format":"atom","item_count":12,
               "audio_item_count":0,"recent_item_titles":[],"source":"html","is_primary":false}
            ]}
            """
        let transport = FakeTransport(json: json)
        let response = try await makeClient(transport)
            .discoverFeeds(url: URL(string: "https://publication.example")!)

        #expect(response.candidates.count == 2)
        #expect(response.candidates[0].isPrimary)
        #expect(response.candidates[0].isArticleFeed)
        #expect(response.candidates[0].recentItemTitles == ["The newest post"])
        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/feeds/discover")
        let body = try JSONDecoder().decode(
            [String: String].self, from: try #require(request.httpBody))
        #expect(body["url"] == "https://publication.example")
    }

    @Test func searchesTheWholeLibraryForEpisodes() async throws {
        let json = """
            [{"id":31,"title":"The Fall of Constantinople","description":null,
              "author":null,"feed_title":"The History Hour",
              "audio_url":"https://cdn.example.com/hh/103.mp3","duration_seconds":3723,
              "published_at":null,"link":null}]
            """
        let transport = FakeTransport(json: json)

        let episodes = try await makeClient(transport)
            .searchLibraryEpisodes(query: "constantinople")

        #expect(episodes.first?.feedTitle == "The History Hour")
        #expect(transport.lastRequest?.url?.path == "/search/episodes")
        #expect(transport.lastRequest?.url?.query?.contains("q=constantinople") == true)
    }

    @Test func explicitWebSearchPostsOnlyTheQuery() async throws {
        let json = """
            {"title":"Notes on Progress","feed_url":"https://notesonprogress.example/feed",
             "publisher":null,"episode_count":null,"artwork_url":null}
            """
        let transport = FakeTransport(json: json)

        let result = try await makeClient(transport)
            .searchPublicationOnWeb(query: "Notes on Progress")

        #expect(result?.title == "Notes on Progress")
        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/search/publications")
        let body = try JSONDecoder().decode(
            [String: String].self, from: try #require(request.httpBody))
        #expect(body == ["query": "Notes on Progress"])
    }

    @Test func subscribePostsToFeeds() async throws {
        let json = """
            {"id":7,"url":"https://feeds.example.com/x","title":"The History Hour",
             "description":null,"image_url":null,"episode_count":3}
            """
        let transport = FakeTransport(status: 201, json: json)
        let show = try await makeClient(transport)
            .subscribe(feedURL: URL(string: "https://feeds.example.com/x")!)

        #expect(show.title == "The History Hour")
        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/feeds")
    }

    @Test func alreadySubscribedConflictIsSpeakable() async {
        do {
            _ = try await makeClient(FakeTransport(status: 409, json: "{}"))
                .subscribe(feedURL: URL(string: "https://feeds.example.com/x")!)
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(!error.spokenResponse.isEmpty)
        } catch {
            Issue.record("wrong error type")
        }
    }
}

@Suite("Auth and positions", .serialized)
struct AuthAndPositionTests {
    /// tokenProvider is process-global, so these tests run serialized and
    /// always restore it.
    private func withToken<T>(_ token: String?, _ body: () async throws -> T) async rethrows -> T {
        let previous = HearfulAPI.tokenProvider
        HearfulAPI.tokenProvider = { token }
        defer { HearfulAPI.tokenProvider = previous }
        return try await body()
    }

    @Test func attachesBearerTokenToRequests() async throws {
        let transport = FakeTransport(json: "[]")
        try await withToken("secret-token") {
            _ = try await makeClient(transport).shows()
        }
        let header = transport.lastRequest?.value(forHTTPHeaderField: "Authorization")
        #expect(header == "Bearer secret-token")
    }

    @Test func sendsNoHeaderWhenSignedOut() async throws {
        let transport = FakeTransport(json: "[]")
        try await withToken(nil) {
            _ = try await makeClient(transport).shows()
        }
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func unauthorizedIsFlaggedAsAuthFailure() async throws {
        let json = #"{"detail":{"spoken_response":"Please open Hearful and sign in."}}"#
        await withToken("stale") {
            do {
                _ = try await makeClient(FakeTransport(status: 401, json: json)).shows()
                Issue.record("expected a thrown error")
            } catch let error as APIError {
                #expect(error.isAuthFailure)
                #expect(error.spokenResponse == "Please open Hearful and sign in.")
            } catch {
                Issue.record("wrong error type")
            }
        }
    }

    @Test func loginPostsTheIdentityToken() async throws {
        let json = #"{"token":"session-1","user":{"id":"u1","display_name":null}}"#
        let transport = FakeTransport(json: json)
        let response = try await withToken(nil) {
            try await makeClient(transport).login(
                appleIdentityToken: "apple-jwt", authorizationCode: nil)
        }

        #expect(response.token == "session-1")
        #expect(response.user.aiDataSharingConsented == false)
        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/auth/apple")
        let body = try JSONDecoder().decode(
            [String: String].self, from: try #require(request.httpBody))
        #expect(body["identity_token"] == "apple-jwt")
    }

    @Test func consentChoiceSendsAPutAndDecodesTheCurrentState() async throws {
        let json = #"{"id":"u1","display_name":null,"ai_data_sharing_consented":true}"#
        let transport = FakeTransport(json: json)

        let user = try await withToken("tok") {
            try await makeClient(transport).setAIDataSharing(granted: true)
        }

        #expect(user.aiDataSharingConsented)
        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/me/ai-data-sharing")
        let body = try JSONDecoder().decode(
            [String: Bool].self, from: try #require(request.httpBody))
        #expect(body["granted"] == true)
    }

    @Test func loginForwardsTheAuthorizationCode() async throws {
        // What lets the backend revoke her Apple grant when she deletes the
        // account. Single-use, so if it does not go with the sign-in it is
        // gone.
        let json = #"{"token":"session-1","user":{"id":"u1","display_name":null}}"#
        let transport = FakeTransport(json: json)
        _ = try await withToken(nil) {
            try await makeClient(transport).login(
                appleIdentityToken: "apple-jwt", authorizationCode: "code-123")
        }

        let body = try JSONDecoder().decode(
            [String: String].self, from: try #require(transport.lastRequest?.httpBody))
        #expect(body["authorization_code"] == "code-123")
    }

    @Test func loginOmitsTheCodeWhenThereIsNone() async throws {
        // The backend treats it as optional; sending null would be noise.
        let json = #"{"token":"session-1","user":{"id":"u1","display_name":null}}"#
        let transport = FakeTransport(json: json)
        _ = try await withToken(nil) {
            try await makeClient(transport).login(
                appleIdentityToken: "apple-jwt", authorizationCode: nil)
        }

        let body = try JSONDecoder().decode(
            [String: String].self, from: try #require(transport.lastRequest?.httpBody))
        #expect(body["authorization_code"] == nil)
    }

    @Test func reportPositionSendsAPut() async throws {
        let transport = FakeTransport(status: 204, json: "")
        try await withToken("tok") {
            try await makeClient(transport).reportPosition(
                episodeID: 104, seconds: 125.5, completed: false)
        }

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/episodes/104/position")
        let body = try JSONSerialization.jsonObject(
            with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["position_seconds"] as? Double == 125.5)
        #expect(body?["completed"] as? Bool == false)
    }

    @Test func episodeDecodesSavedPosition() async throws {
        let json = """
            {"id":104,"title":"t","description":null,"audio_url":"https://x/y.mp3",
             "duration_seconds":2700,"published_at":null,"link":null,
             "position_seconds":125.5,"completed":false}
            """
        let episode = try await makeClient(FakeTransport(json: json)).episode(id: 104)
        #expect(episode.positionSeconds == 125.5)
        #expect(episode.completed == false)
    }

    @Test func episodeWithoutPositionFieldsStillDecodes() async throws {
        // Payload shape from before positions existed.
        let json = """
            {"id":104,"title":"t","description":null,"audio_url":null,
             "duration_seconds":null,"published_at":null,"link":null}
            """
        let episode = try await makeClient(FakeTransport(json: json)).episode(id: 104)
        #expect(episode.positionSeconds == nil)
        #expect(episode.imageURL == nil)
    }

    @Test func episodeDecodesArtwork() async throws {
        let json = """
            {"id":104,"title":"t","description":null,"audio_url":null,
             "duration_seconds":null,"published_at":null,"link":null,
             "image_url":"https://example.com/ep104.jpg"}
            """
        let episode = try await makeClient(FakeTransport(json: json)).episode(id: 104)
        #expect(episode.imageURL?.absoluteString == "https://example.com/ep104.jpg")
    }

    @Test func commandDecodesSetSpeed() async throws {
        let json = """
            {"action":"set_speed","spoken_response":"1.5 times speed.",
             "episode":null,"speed":1.5}
            """
        let result = try await makeClient(FakeTransport(json: json)).command(transcript: "faster", nowPlayingEpisodeID: nil, traceparent: nil)
        #expect(result.action == .setSpeed)
        #expect(result.speed == 1.5)
    }
}

@Suite("Command endpoint failures")
struct CommandFailureTests {
    @Test func serviceUnavailableSurfacesSpeakableMessage() async throws {
        // The backend puts something sayable in the 503 body; losing it would
        // leave the app with nothing to tell her.
        let json = """
            {"detail":{"spoken_response":"Sorry, I cannot reach my assistant right now.",
            "error":"upstream timeout"}}
            """
        do {
            _ = try await makeClient(FakeTransport(status: 503, json: json))
                .command(transcript: "x", nowPlayingEpisodeID: nil, traceparent: nil)
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(error.spokenResponse == "Sorry, I cannot reach my assistant right now.")
        }
    }

    @Test func plainServerErrorStillHasSomethingToSay() async throws {
        do {
            _ = try await makeClient(FakeTransport(status: 500, json: "internal server error"))
                .command(transcript: "x", nowPlayingEpisodeID: nil, traceparent: nil)
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(!error.spokenResponse.isEmpty)
        }
    }

    @Test func transportFailureIsSpeakable() async throws {
        do {
            _ = try await makeClient(FakeTransport(failure: URLError(.notConnectedToInternet)))
                .command(transcript: "x", nowPlayingEpisodeID: nil, traceparent: nil)
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(!error.spokenResponse.isEmpty)
        }
    }

    @Test func malformedBodyIsSpeakable() async throws {
        do {
            _ = try await makeClient(FakeTransport(json: "{\"action\": \"nonsense\"}"))
                .command(transcript: "x", nowPlayingEpisodeID: nil, traceparent: nil)
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(!error.spokenResponse.isEmpty)
        }
    }
}

@Suite("Trace context on the wire")
struct TraceHeaderTests {
    @Test func aCommandCarriesTheTraceItWasGiven() async throws {
        let transport = FakeTransport(json: playJSON)
        _ = try await makeClient(transport).command(
            transcript: "x", nowPlayingEpisodeID: nil, traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")

        let sent = transport.lastRequest?.value(forHTTPHeaderField: "traceparent")
        #expect(sent == "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
    }

    @Test func aRequestWithNoTraceSendsNoHeader() async throws {
        // Siri phrases have no listening attempt behind them to belong to, so
        // the backend should start its own trace rather than be handed a
        // malformed one.
        let transport = FakeTransport(json: playJSON)
        _ = try await makeClient(transport).command(transcript: "x", nowPlayingEpisodeID: nil, traceparent: nil)

        #expect(transport.lastRequest?.value(forHTTPHeaderField: "traceparent") == nil)
    }
}
