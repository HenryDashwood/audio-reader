import Foundation
import Testing

@testable import Hearful

private func makeCache() -> OfflineCache {
    let directory = URL.temporaryDirectory.appending(path: "search-tests-\(UUID().uuidString)")
    return OfflineCache(directory: directory)
}

private func episode(id: Int, title: String = "An episode") -> Episode {
    Episode(
        id: id, title: title, description: nil,
        audioURL: URL(string: "https://cdn.example.com/\(id).mp3"), durationSeconds: 600,
        publishedAt: nil, link: nil)
}

/// Short, because nothing here waits on the clock: the tests await the
/// model's own task, which includes this pause.
private let debounce = Duration.milliseconds(1)

@Suite("Searching inside a show")
@MainActor
struct EpisodeSearchTests {
    @Test func aQueryGoesToTheBackendRatherThanFilteringWhatIsLoaded() async {
        // The app holds the newest fifty; the episode being looked for is
        // usually older than that.
        let api = FakeAPI()
        api.episodesByID = [1: episode(id: 1)]
        api.searchResults = [episode(id: 99, title: "Krakatoa")]
        let model = EpisodeListModel(api: api, cache: makeCache(), debounce: debounce)

        model.queryChanged("krakatoa", showID: 3)
        await model.pending?.value

        #expect(api.episodeQueries.last == "krakatoa")
        guard case .loaded(let episodes) = model.state else {
            Issue.record("expected results, got \(model.state)")
            return
        }
        #expect(episodes.map(\.id) == [99])
    }

    @Test func typingBurstBecomesOneRequest() async {
        let api = FakeAPI()
        api.searchResults = []
        let model = EpisodeListModel(api: api, cache: makeCache(), debounce: debounce)

        for query in ["k", "kr", "kra", "krak"] {
            model.queryChanged(query, showID: 3)
        }
        await model.pending?.value

        #expect(api.episodeQueries == ["krak"])
    }

    @Test func clearingTheBoxAsksForTheShowAgain() async {
        let api = FakeAPI()
        api.episodesByID = [1: episode(id: 1)]
        api.searchResults = [episode(id: 99, title: "Krakatoa")]
        let model = EpisodeListModel(api: api, cache: makeCache(), debounce: debounce)

        model.queryChanged("krakatoa", showID: 3)
        await model.pending?.value
        model.queryChanged("", showID: 3)
        await model.pending?.value

        #expect(api.episodeQueries == ["krakatoa", nil])
        #expect(model.isSearching == false)
    }

    @Test func whitespaceIsNotASearch() async {
        let api = FakeAPI()
        let model = EpisodeListModel(api: api, cache: makeCache(), debounce: debounce)

        model.queryChanged("   ", showID: 3)
        await model.pending?.value

        #expect(api.episodeQueries == [nil])
        #expect(model.isSearching == false)
    }

    @Test func resultsAreNotWrittenOverTheSavedShow() async {
        // Three episodes about volcanoes saved as "the show" would be what she
        // got the next time she opened it with no signal.
        let cache = makeCache()
        let api = FakeAPI()
        api.episodesByID = [1: episode(id: 1), 2: episode(id: 2)]
        let model = EpisodeListModel(api: api, cache: cache, debounce: debounce)

        await model.load(showID: 3)
        api.searchResults = [episode(id: 99, title: "Krakatoa")]
        model.queryChanged("krakatoa", showID: 3)
        await model.pending?.value

        let saved = cache.load([Episode].self, for: .episodes(showID: 3))
        #expect(saved?.count == 2)
        #expect(saved?.contains { $0.id == 99 } == false)
    }

    @Test func aSearchThatCannotReachTheNetworkDoesNotAnswerWithTheWholeShow() async {
        // Answering "what have you got about Krakatoa?" with the last fifty
        // episodes is not a worse answer, it is a different question.
        let cache = makeCache()
        cache.save([episode(id: 1), episode(id: 2)], for: .episodes(showID: 3))
        let api = FakeAPI()
        api.episodesError = APIError(underlying: "offline")
        let model = EpisodeListModel(api: api, cache: cache, debounce: debounce)

        model.queryChanged("krakatoa", showID: 3)
        await model.pending?.value

        guard case .failed = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
    }

    @Test func openingTheShowStillFallsBackToTheSavedEpisodes() async {
        // The offline path for the show itself is unchanged by any of this.
        let cache = makeCache()
        cache.save([episode(id: 1)], for: .episodes(showID: 3))
        let api = FakeAPI()
        api.episodesError = APIError(underlying: "offline")
        let model = EpisodeListModel(api: api, cache: cache, debounce: debounce)

        await model.load(showID: 3)

        guard case .loaded(let episodes) = model.state else {
            Issue.record("expected the saved episodes, got \(model.state)")
            return
        }
        #expect(episodes.map(\.id) == [1])
        #expect(model.isOffline)
    }

    @Test func aLateAnswerToAnAbandonedSearchIsNotShown() async {
        // She typed on. The older request must not land on top of the newer.
        let api = FakeAPI()
        api.searchResults = [episode(id: 99, title: "Krakatoa")]
        let model = EpisodeListModel(api: api, cache: makeCache(), debounce: debounce)

        model.queryChanged("krak", showID: 3)
        model.queryChanged("krakatoa", showID: 3)
        await model.pending?.value

        #expect(api.episodeQueries == ["krakatoa"])
    }
}
