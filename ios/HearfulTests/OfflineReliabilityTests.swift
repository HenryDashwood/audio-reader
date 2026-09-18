import Foundation
import Testing
@testable import Hearful

private actor OfflineTextTransport: DataTransport {
    var offline = false
    var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requests = 0
    func setOffline() { offline = true }
    func hold() { held = true }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        if held { await withCheckedContinuation { continuation = $0 } }
        if offline { throw URLError(.notConnectedToInternet) }
        let body = #"{"episode_id":42,"content_id":10,"title":"Essay","text":"Text shared by reading and narration.","html":"<p>Text shared by reading and narration.</p>"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
@Suite("Offline content reliability")
struct OfflineReliabilityTests {
    private func cache() -> OfflineCache { OfflineCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)) }
    private func api(_ transport: OfflineTextTransport) -> HearfulAPI {
        HearfulAPI(baseURL: URL(string: "https://example.invalid")!, transport: transport)
    }
    private func episode(contentID: Int? = nil) -> Episode {
        Episode(id: 42, title: "Essay", description: nil, audioURL: nil, durationSeconds: nil,
                publishedAt: nil, link: nil, hasText: true, contentID: contentID)
    }

    @Test func playerFirstAndReaderFirstBothResolveTheSameOfflineVersion() async throws {
        for playerFirst in [true, false] {
            let cache = cache(); defer { cache.clear() }
            let transport = OfflineTextTransport()
            let player = ArticlePlayer(api: api(transport), cache: cache, synthesizer: SilentSynthesizer(),
                                       progressScope: { nil }, activateAudioSession: {})
            defer { player.clear() }
            if playerFirst {
                player.prepare(episode())
                for _ in 0..<200 where !player.isReadyToPlay { try await Task.sleep(for: .milliseconds(5)) }
                #expect(player.isReadyToPlay)
            } else {
                await ArticleTextModel(api: api(transport), cache: cache).load(episodeID: 42)
            }
            await transport.setOffline()
            for contentID: Int? in [nil, 10] {
                let reader = ArticleTextModel(api: api(transport), cache: cache)
                await reader.load(episodeID: 42, contentID: contentID)
                guard case .loaded(let article) = reader.state else { Issue.record("Reader lost cached article"); continue }
                #expect(article.text.contains("reading and narration"))
                #expect(reader.isOffline)
            }
            #expect(cache.article(episodeID: 42, contentID: 11) == nil)
        }
    }

    @Test func cachedTextIsVisibleBeforeAStalledRequestReturns() async throws {
        let cache = cache(); defer { cache.clear() }
        cache.saveArticle(EpisodeText(episodeID: 42, contentID: 10, title: "Essay", text: "Offline body"))
        let transport = OfflineTextTransport(); await transport.hold(); await transport.setOffline()
        let model = ArticleTextModel(api: api(transport), cache: cache)
        let task = Task { await model.load(episodeID: 42, contentID: 10) }
        for _ in 0..<200 {
            if await transport.requests > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        if case .loaded(let article) = model.state { #expect(article.text == "Offline body") }
        else { Issue.record("Cached text was hidden behind a network request") }
        await transport.release(); _ = await task.value
        #expect(model.isOffline)
    }

    @Test func legacyVersionedTextMigratesWithoutGuessingOtherVersions() {
        let cache = cache(); defer { cache.clear() }
        let text = EpisodeText(episodeID: 42, contentID: 10, title: "Essay", text: "Old cache")
        cache.save(text, for: .articleText(episodeID: 42))
        #expect(cache.article(episodeID: 42, contentID: 10) == text)
        #expect(cache.article(episodeID: 42, contentID: 11) == nil)
        cache.save(text, for: .articleVersion(episodeID: 99, contentID: 10))
        #expect(cache.article(episodeID: 99, contentID: 10) == nil)
        cache.clear()
        cache.save(text, for: .articleVersion(episodeID: 42, contentID: 10))
        cache.save([episode(contentID: 10)], for: .savedArticles)
        #expect(cache.article(episodeID: 42) == text)
    }

    @Test func failedDiskWriteCannotClaimOfflineAvailability() throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("not a directory".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = OfflineCache(directory: url)
        #expect(!cache.saveArticle(EpisodeText(episodeID: 42, title: "Essay", text: "Words")))
        #expect(cache.article(episodeID: 42) == nil)
    }

    @Test func lastPlayedSnapshotSurvivesReopeningButNeverCrossesAccounts() {
        let suite = UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PlaybackRestore.remember(episode(contentID: 10), defaults: defaults, scope: "first-account")
        #expect(PlaybackRestore.cached(id: 42, defaults: defaults, scope: "first-account") == episode(contentID: 10))
        #expect(PlaybackRestore.cached(id: 42, defaults: defaults, scope: "second-account") == nil)
        PlaybackRestore.forget(defaults: defaults)
        #expect(PlaybackRestore.cached(id: 42, defaults: defaults, scope: "first-account") == nil)
    }

    @Test func localVoiceCommandsDoNotRequireRemoteConsent() async {
        let recorder = Recorder(); let speech = FakeSpeech(); let api = FakeAPI()
        let player = FakePlayer(recorder)
        let controller = VoiceController(api: api, speech: speech, speaker: FakeSpeaker(recorder), player: player,
            feedback: FakeFeedback(recorder), conversationPreferences: { VoiceConversationPreferences(keepListening: false) })
        controller.remoteRequestsAllowed = false
        await controller.beginCommand(transcript: "pause")
        #expect(recorder.events.contains(.paused))
        #expect(api.transcripts.isEmpty)
        await controller.beginCommand(transcript: "find a new podcast")
        #expect(api.transcripts.isEmpty)
        #expect(recorder.spoken.last?.contains("Playback commands work on this device") == true)
    }
}
