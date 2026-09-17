import Foundation
import Testing
@testable import Hearful

@MainActor
private final class BookmarkMemoryStorage: ArticleProgressStorage {
    var rows: [String: [QueuedArticleProgress]] = [:]
    var failWrites = false
    func read(owner: String) throws -> [QueuedArticleProgress] { rows[owner] ?? [] }
    func write(owner: String, entries: [QueuedArticleProgress]) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        rows[owner] = entries
    }
}

@MainActor
@Suite("Durable article bookmarks")
struct ArticleProgressJournalTests {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let c = String(repeating: "c", count: 64)
    private let text = String(repeating: "e", count: 64)
    private func sample(_ offset: Int, completed: Bool = false) -> ArticleProgressSample {
        .init(textVersion: text, contentID: 7, offsetUTF16: offset, completed: completed)
    }
    private func state(_ revision: String) -> ArticleProgressState {
        .init(textVersion: text, contentID: 7, revision: revision, bookmark: nil)
    }
    private func receipt(_ revision: String, accepted: String? = nil) -> ArticleProgressReceipt {
        let episode = Episode(id: 1, title: "Article", description: nil, audioURL: nil,
            durationSeconds: nil, publishedAt: nil, link: nil, positionSeconds: nil, completed: false, hasText: true, contentID: 7)
        return .init(episode: episode, progress: state(revision), acceptedRevision: accepted ?? revision)
    }
    @Test func preparationDoesNotReportAndLostRepliesKeepExactBodyAcrossRecreation() async throws {
        let store = BookmarkMemoryStorage(); let journal = ArticleProgressJournal(store: store); let playback = UUID()
        try journal.start(owner: a, episodeID: 1, playbackID: playback, progress: state(a), sample: sample(0))
        try await journal.flush(owner: a, valid: { true }, send: { _, _ in Issue.record("Preparation reported zero"); return receipt(b) })
        try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(10))
        let original = try #require(journal.entries(owner: a).first?.pending)
        do {
            try await journal.flush(owner: a, valid: { true }, send: { _, report in
                #expect(report == original); throw URLError(.networkConnectionLost)
            })
            Issue.record("Expected lost reply")
        } catch is URLError { }
        try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(20))
        let reopened = ArticleProgressJournal(store: store)
        try await reopened.flush(owner: a, valid: { true }, send: { _, report in #expect(report == original); return receipt(b) })
        let tail = try #require(reopened.entries(owner: a).first?.pending)
        #expect(tail.requestID != original.requestID); #expect(tail.expectedRevision == b); #expect(tail.offsetUTF16 == 20)
        try await reopened.flush(owner: a, valid: { true }, send: { _, report in #expect(report == tail); return receipt(c) })
        #expect(try reopened.entries(owner: a).first?.pending == nil)
    }
    @Test func completionCannotBeUndoneByALatePauseAndNewerFilingBlocksTheOldClock() async throws {
        let journal = ArticleProgressJournal(store: BookmarkMemoryStorage()); let playback = UUID()
        try journal.start(owner: a, episodeID: 1, playbackID: playback, progress: state(a), sample: sample(0))
        try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(10))
        try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(100, completed: true))
        #expect(try !journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(99)))
        try await journal.flush(owner: a, valid: { true }, send: { _, _ in receipt(c, accepted: b) })
        #expect(try journal.entries(owner: a).first?.blocked == true)
        #expect(try !journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(101, completed: true)))
    }
    @Test func filingDuringInflightRequestRetiresItsLateAcknowledgement() async throws {
        let journal = ArticleProgressJournal(store: BookmarkMemoryStorage()); let playback = UUID()
        try journal.start(owner: a, episodeID: 1, playbackID: playback, progress: state(a), sample: sample(0))
        try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(10))
        var applied = false
        try await journal.flush(owner: a, valid: { true }, send: { _, _ in
            try journal.block(owner: a, episodeIDs: [1]); return receipt(b)
        }, applied: { _ in applied = true })
        #expect(!applied); #expect(try journal.entries(owner: a).first?.pending == nil)
    }
    @Test func newerSamplesDuringUploadArePreservedAndTheirOwnReceiptAdvancesTheBaseline() async throws {
        let journal = ArticleProgressJournal(store: BookmarkMemoryStorage()); let playback = UUID()
        try journal.start(owner: a, episodeID: 1, playbackID: playback, progress: state(a), sample: sample(0))
        try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(10))
        try await journal.flush(owner: a, valid: { true }, send: { _, _ in
            try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(20)); return receipt(b)
        })
        #expect(try journal.resume(owner: a, episodeID: 1, progress: state(b)) == sample(20))
        #expect(try journal.resume(owner: a, episodeID: 1, progress: state(c)) == nil)
        #expect(try journal.entries(owner: a).first?.pending?.expectedRevision == b)
    }
    @Test func changedTextCannotSupplyCoordinatesToAnOldPendingRequest() async throws {
        let journal = ArticleProgressJournal(store: BookmarkMemoryStorage()); let first = UUID(); let second = UUID()
        try journal.start(owner: a, episodeID: 1, playbackID: first, progress: state(a), sample: sample(0))
        try journal.record(owner: a, episodeID: 1, playbackID: first, sample: sample(10))
        let replacement = ArticleProgressSample(textVersion: c, contentID: 8, offsetUTF16: 7, completed: false)
        let progress = ArticleProgressState(textVersion: c, contentID: 8, revision: c, bookmark: nil)
        try journal.start(owner: a, episodeID: 1, playbackID: second, progress: progress, sample: replacement)
        #expect(try !journal.record(owner: a, episodeID: 1, playbackID: second, sample: sample(20)))
        try journal.record(owner: a, episodeID: 1, playbackID: second, sample: replacement)
        try await journal.flush(owner: a, valid: { true }, send: { _, report in
            #expect(report.textVersion == text); #expect(report.contentID == 7)
            return ArticleProgressReceipt(episode: receipt(c).episode, progress: progress, acceptedRevision: b)
        })
        let tail = try #require(journal.entries(owner: a).first?.pending)
        #expect(tail.textVersion == c); #expect(tail.contentID == 8); #expect(tail.offsetUTF16 == 7); #expect(tail.expectedRevision == c)
    }
    @Test func requestGuardsSurviveRecreationAndNewExplicitPlayUntilTheirOwnConfirmation() async throws {
        let store = BookmarkMemoryStorage(); let journal = ArticleProgressJournal(store: store); let playback = UUID()
        try journal.start(owner: a, episodeID: 1, playbackID: playback, progress: state(a), sample: sample(0))
        try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(10))
        try journal.hold(owner: a, episodeIDs: [1], requestID: "one"); try journal.hold(owner: a, episodeIDs: [1], requestID: "two")
        let reopened = ArticleProgressJournal(store: store); let second = UUID()
        try reopened.start(owner: a, episodeID: 1, playbackID: second, progress: state(a), sample: sample(0))
        try reopened.confirm(owner: a, requestID: "one")
        #expect(try !reopened.record(owner: a, episodeID: 1, playbackID: second, sample: sample(20)))
        try await reopened.flush(owner: a, valid: { true }, send: { _, _ in Issue.record("Unconfirmed filing reported"); return receipt(b) })
        try reopened.confirm(owner: a, requestID: "two")
        #expect(try reopened.record(owner: a, episodeID: 1, playbackID: second, sample: sample(20)))
    }
    @Test func signOutDuringNetworkWaitCannotRestoreTheClearedJournalOrNotifyObservers() async throws {
        let journal = ArticleProgressJournal(store: BookmarkMemoryStorage()); let playback = UUID(); var valid = true; var applied = false
        try journal.start(owner: a, episodeID: 1, playbackID: playback, progress: state(a), sample: sample(0))
        try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(10))
        do {
            try await journal.flush(owner: a, valid: { valid }, send: { _, _ in
                valid = false; try journal.clear(owner: a); return receipt(b)
            }, applied: { _ in applied = true })
            Issue.record("Expected cancelled session")
        } catch is CancellationError { }
        #expect(!applied); #expect(try journal.entries(owner: a).isEmpty)
    }
    @Test func diskFailureDoesNotAuthorizeARequestThatWasNotPersisted() throws {
        let store = BookmarkMemoryStorage(); let journal = ArticleProgressJournal(store: store); let playback = UUID()
        try journal.start(owner: a, episodeID: 1, playbackID: playback, progress: state(a), sample: sample(0))
        store.failWrites = true
        #expect(throws: CocoaError.self) { try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(10)) }
        #expect(try journal.entries(owner: a).first?.pending == nil)
    }
    @Test func atomicStorageSurvivesRecreationAndRejectsCorruptionWithoutDeletingGuards() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileArticleProgressStorage(directory: directory); let journal = ArticleProgressJournal(store: store); let playback = UUID()
        try journal.start(owner: a, episodeID: 1, playbackID: playback, progress: state(a), sample: sample(0))
        try journal.record(owner: a, episodeID: 1, playbackID: playback, sample: sample(10))
        try journal.hold(owner: a, episodeIDs: [1], requestID: "uncertain-filing")
        let reopened = FileArticleProgressStorage(directory: directory)
        #expect(try reopened.read(owner: a) == store.read(owner: a)); #expect(try reopened.read(owner: b).isEmpty)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let file = directory.appending(path: a + ".json")
        try Data("{broken".utf8).write(to: file)
        #expect(throws: (any Error).self) { try reopened.read(owner: a) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{broken")
        #expect(throws: (any Error).self) { try reopened.read(owner: "../escape") }
    }
    @Test func unicodeCoordinatesRejectSurrogateHalvesAndResumeBeforeTheTargetAcrossChunks() {
        let text = "Café 🌱 in the garden.\n\nAnother 🦉 passage beside the river.\n\nThe final paragraph."
        let script = ArticleScript(text: text)
        // Shared with Android ArticleChunksTest: exact source bytes and UTF-16 coordinate.
        #expect(ArticleScript.textVersion(text) == "8dbce6391279ec2806c0340ed5f585cdce28dcea1e0da494679c84d18dfc9a88")
        #expect(ArticleScript.isScalarBoundary(5, in: text))
        #expect(!ArticleScript.isScalarBoundary(6, in: text))
        #expect(ArticleScript.isScalarBoundary(7, in: text))
        let offset = (text as NSString).range(of: "🦉").location
        let index = script.index(atUTF16: offset)!
        #expect(offset == 32); #expect(script.chunks[index].textRange.location == 24)
        #expect(script.chunks[index].text.hasPrefix("Another"))
        #expect(script.chunks[index].textRange.location <= offset)
        #expect(script.chunks[index].textRange.location + script.chunks[index].textRange.length > offset)
        #expect(ArticleScript.textVersion(text) != ArticleScript.textVersion(text + " "))
    }
}
