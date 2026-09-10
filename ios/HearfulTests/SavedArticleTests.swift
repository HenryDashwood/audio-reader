import Foundation
import Testing

@testable import Hearful

struct SavedArticleTests {
    @Test func aQueuedReplacementRetainsItsIntentAndOlderCapturesStillDecode() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = CaptureInbox(directory: directory)
        let account = CaptureInbox.Account(userID: "first", server: URL(string: "https://example.com")!)
        try inbox.configure(account)
        let saved = try inbox.save(
            url: URL(string: "https://example.com/story")!, html: "<article>Correct text</article>",
            contentFormat: "article", replaceExisting: true)
        let reopened = CaptureInbox(directory: directory)
        #expect(reopened.pending(for: account).first?.contentFormat == "article")
        #expect(reopened.pending(for: account).first?.replaceExisting == true)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        old.removeValue(forKey: "contentFormat")
        old.removeValue(forKey: "replaceExisting")
        let decoded = try JSONDecoder().decode(CaptureInbox.Capture.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.contentFormat == nil)
        #expect(decoded.replaceExisting == nil)
        #expect(decoded.url == saved.url)
    }
    @Test func capturesSurviveReopeningAndStayWithTheirAccountAndServer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = CaptureInbox(directory: directory)
        let account = CaptureInbox.Account(
            userID: "first", server: URL(string: "https://one.example")!)
        try inbox.configure(account)
        let first = try inbox.save(
            url: URL(string: "https://example.com/article")!, title: "An essay",
            html: "<p>Private text</p>")
        let reopened = CaptureInbox(directory: directory)
        #expect(reopened.pending(for: account).map(\.id) == [first.id])
        #expect(reopened.pending(for: .init(userID: "second", server: account.server)).isEmpty)
        #expect(
            reopened.pending(
                for: .init(userID: account.userID, server: URL(string: "https://two.example")!)
            ).isEmpty)
        let second = try inbox.save(url: URL(string: "https://example.com/another")!)
        try inbox.remove(first)
        #expect(inbox.pending(for: account).map(\.id) == [second.id])
        inbox.signOut()
        #expect(inbox.account == nil)
        #expect(inbox.pending(for: account).isEmpty)
    }

    @Test func invalidLinksAndUnavailableStorageDoNotClaimSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = CaptureInbox(directory: directory)
        #expect(throws: CaptureInbox.InboxError.self) {
            try inbox.save(url: URL(string: "https://example.com")!)
        }
        try inbox.configure(.init(userID: "user", server: URL(string: "https://one.example")!))
        #expect(throws: CaptureInbox.InboxError.self) {
            try inbox.save(url: URL(string: "file:///private/article")!)
        }
        #expect(throws: CaptureInbox.InboxError.self) {
            try inbox.save(url: URL(string: "https://user:secret@example.com")!)
        }
        #expect(throws: CaptureInbox.InboxError.self) {
            try CaptureInbox(directory: nil).configure(
                .init(userID: "user", server: URL(string: "https://one.example")!))
        }
    }

    @Test func offlineVersionsCannotOverwriteOneAnother() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let cache = OfflineCache(directory: directory)
        defer { cache.clear() }
        let original = EpisodeText(
            episodeID: 42, contentID: 10, title: "Essay", text: "Original words")
        let revised = EpisodeText(
            episodeID: 42, contentID: 11, title: "Essay", text: "Revised words")
        cache.save(original, for: .articleVersion(episodeID: 42, contentID: 10))
        cache.save(revised, for: .articleVersion(episodeID: 42, contentID: 11))
        #expect(
            cache.load(EpisodeText.self, for: .articleVersion(episodeID: 42, contentID: 10))
                == original)
        #expect(
            cache.load(EpisodeText.self, for: .articleVersion(episodeID: 42, contentID: 11))
                == revised)
        #expect(cache.load(EpisodeText.self, for: .articleText(episodeID: 42)) == nil)
    }
}

@MainActor
struct SavedArticlePlaybackTests {
    @Test func aStaleListCannotApplyOldSecondsToANewSnapshot() async {
        let cache = OfflineCache(
            directory: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { cache.clear() }
        cache.save(
            EpisodeText(
                episodeID: 42, contentID: 10, title: "Essay",
                text: String(repeating: "These are the new words.\n\n", count: 30)),
            for: .articleText(episodeID: 42))
        let player = ArticlePlayer(api: FakeAPI(), cache: cache, synthesizer: SilentSynthesizer())
        let stale = Episode(
            id: 42, title: "Essay", description: nil, audioURL: nil, durationSeconds: nil,
            publishedAt: nil, link: nil, positionSeconds: 40, hasText: true)
        player.prepare(stale)
        for _ in 0..<100 where player.duration == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.duration > 0)
        #expect(player.currentEpisode?.contentID == 10)
        #expect(player.currentTime == 0)
        player.clear()
    }

    @Test func aReaderNeverCachesAnUnexpectedVersion() async {
        let cache = OfflineCache(
            directory: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { cache.clear() }
        let api = FakeAPI()
        api.articleText = "A different unversioned copy"
        let model = ArticleTextModel(api: api, cache: cache)
        await model.load(episodeID: 42, contentID: 10)
        guard case .failed = model.state else {
            Issue.record("Expected a version mismatch failure")
            return
        }
        #expect(
            cache.load(EpisodeText.self, for: .articleVersion(episodeID: 42, contentID: 10)) == nil)
    }
}
