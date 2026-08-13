import Foundation
import Testing

@testable import Hearful

private func makeCache() -> OfflineCache {
    let directory = URL.temporaryDirectory.appending(path: "cache-tests-\(UUID().uuidString)")
    return OfflineCache(directory: directory)
}

private func show(id: Int, failing: Bool? = nil) -> Show {
    Show(
        id: id, title: "Show \(id)", description: nil, artworkURL: nil, episodeCount: 3,
        isFailing: failing)
}

private func episode(id: Int, published: Date? = nil) -> Episode {
    Episode(
        id: id, title: "Episode \(id)", description: nil,
        audioURL: URL(string: "https://cdn.example.com/\(id).mp3"), durationSeconds: 600,
        publishedAt: published, link: nil)
}

@Suite("Offline cache")
struct OfflineCacheTests {
    @Test func showsRoundTrip() {
        let cache = makeCache()
        cache.save([show(id: 1), show(id: 2)], for: .shows)

        #expect(cache.load([Show].self, for: .shows) == [show(id: 1), show(id: 2)])
    }

    @Test func episodesRoundTripWithTheirDates() {
        // Dates are the one field with a format to get wrong; a published date
        // that comes back nil would reorder her episode list.
        let cache = makeCache()
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        cache.save([episode(id: 7, published: published)], for: .recentEpisodes)

        let loaded = cache.load([Episode].self, for: .recentEpisodes)
        #expect(loaded?.first?.publishedAt == published)
    }

    @Test func nothingCachedReadsAsNil() {
        #expect(makeCache().load([Show].self, for: .shows) == nil)
    }

    @Test func eachShowHasItsOwnEpisodeList() {
        let cache = makeCache()
        cache.save([episode(id: 1)], for: .episodes(showID: 10))
        cache.save([episode(id: 2)], for: .episodes(showID: 20))

        #expect(cache.load([Episode].self, for: .episodes(showID: 10))?.first?.id == 1)
        #expect(cache.load([Episode].self, for: .episodes(showID: 20))?.first?.id == 2)
    }

    @Test func savingAgainReplaces() {
        let cache = makeCache()
        cache.save([show(id: 1), show(id: 2)], for: .shows)
        cache.save([show(id: 3)], for: .shows)

        #expect(cache.load([Show].self, for: .shows) == [show(id: 3)])
    }

    @Test func clearForgetsEverything() {
        // Signing out must not leave the next person her library.
        let cache = makeCache()
        cache.save([show(id: 1)], for: .shows)
        cache.save([episode(id: 1)], for: .recentEpisodes)

        cache.clear()

        #expect(cache.load([Show].self, for: .shows) == nil)
        #expect(cache.load([Episode].self, for: .recentEpisodes) == nil)
    }

    @Test func unreadableCacheIsDiscardedRatherThanCrashing() {
        // What a shape change between app versions looks like on disk.
        let cache = makeCache()
        try? FileManager.default.createDirectory(
            at: cache.directory, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: cache.directory.appending(path: "shows.json"))

        #expect(cache.load([Show].self, for: .shows) == nil)
    }

    @Test func aFeedFlaggedAsFailingSurvivesTheRoundTrip() {
        let cache = makeCache()
        cache.save([show(id: 1, failing: true)], for: .shows)

        #expect(cache.load([Show].self, for: .shows)?.first?.isFailing == true)
    }
}

@Suite("Library falls back to the cache")
@MainActor
struct LibraryOfflineTests {
    @Test func aSuccessfulLoadIsCached() async {
        let cache = makeCache()
        let api = FakeAPI()
        api.shows = [show(id: 1)]
        let model = LibraryModel(api: api, cache: cache)

        await model.load()

        #expect(cache.load([Show].self, for: .shows) == [show(id: 1)])
    }

    @Test func aFailureShowsTheCachedShows() async {
        let cache = makeCache()
        cache.save([show(id: 1)], for: .shows)
        let api = FakeAPI()
        api.showsError = APIError(underlying: "offline")
        let model = LibraryModel(api: api, cache: cache)

        await model.load()

        guard case .stale(let shows) = model.state else {
            Issue.record("expected the cached shows, got \(model.state)")
            return
        }
        #expect(shows == [show(id: 1)])
    }

    @Test func aFailureWithNothingCachedStillFails() async {
        let api = FakeAPI()
        api.showsError = APIError(underlying: "offline")
        let model = LibraryModel(api: api, cache: makeCache())

        await model.load()

        guard case .failed = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
    }

    @Test func anExpiredSessionIsNotPaperedOver() async {
        // Showing her library from the cache while every tap 401s would be
        // worse than saying plainly that she needs to sign in.
        let cache = makeCache()
        cache.save([show(id: 1)], for: .shows)
        let api = FakeAPI()
        api.showsError = APIError(underlying: "HTTP 401", isAuthFailure: true)
        let model = LibraryModel(api: api, cache: cache)

        await model.load()

        guard case .failed = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
    }
}
