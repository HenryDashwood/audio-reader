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
