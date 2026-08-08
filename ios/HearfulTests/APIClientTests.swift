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
            .command(transcript: "play the Vienna one")

        #expect(result.action == .playEpisode)
        #expect(result.spokenResponse == "Playing The Congress of Vienna.")
        #expect(result.episode?.title == "The Congress of Vienna")
        #expect(result.episode?.audioURL?.absoluteString == "https://cdn.example.com/104.mp3")
        #expect(result.episode?.durationSeconds == 2700)
    }

    @Test func decodesPublishedDate() async throws {
        let result = try await makeClient(FakeTransport(json: playJSON)).command(transcript: "x")
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
        let result = try await makeClient(FakeTransport(json: json)).command(transcript: "x")
        #expect(result.episode?.publishedAt != nil)
    }

    @Test func decodesUnknownWithNoEpisode() async throws {
        let json = """
            {"action":"unknown","spoken_response":"Which show would you like?","episode":null}
            """
        let result = try await makeClient(FakeTransport(json: json))
            .command(transcript: "play the thing")

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
        let result = try await makeClient(FakeTransport(json: json)).command(transcript: "x")

        #expect(result.action == .unknown)
        #expect(result.spokenResponse == "Subscribed to The Rest Is History.")
    }

    @Test func sendsTranscriptAsJSONPost() async throws {
        let transport = FakeTransport(json: playJSON)
        _ = try await makeClient(transport).command(transcript: "play the Vienna one")

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/command")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONDecoder().decode(
            [String: String].self, from: try #require(request.httpBody))
        #expect(body["transcript"] == "play the Vienna one")
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
                .command(transcript: "x")
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(error.spokenResponse == "Sorry, I cannot reach my assistant right now.")
        }
    }

    @Test func plainServerErrorStillHasSomethingToSay() async throws {
        do {
            _ = try await makeClient(FakeTransport(status: 500, json: "internal server error"))
                .command(transcript: "x")
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(!error.spokenResponse.isEmpty)
        }
    }

    @Test func transportFailureIsSpeakable() async throws {
        do {
            _ = try await makeClient(FakeTransport(failure: URLError(.notConnectedToInternet)))
                .command(transcript: "x")
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(!error.spokenResponse.isEmpty)
        }
    }

    @Test func malformedBodyIsSpeakable() async throws {
        do {
            _ = try await makeClient(FakeTransport(json: "{\"action\": \"nonsense\"}"))
                .command(transcript: "x")
            Issue.record("expected a thrown error")
        } catch let error as APIError {
            #expect(!error.spokenResponse.isEmpty)
        }
    }
}
