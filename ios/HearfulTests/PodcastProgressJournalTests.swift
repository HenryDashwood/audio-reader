import Foundation
import Testing
@testable import Hearful

@MainActor
@Suite("Durable offline podcast positions")
struct PodcastProgressJournalTests {
    private let owner = String(repeating: "a", count: 64)
    private let next = String(repeating: "b", count: 64)
    private let newer = String(repeating: "c", count: 64)
    private func episode(_ revision: String) -> Episode {
        Episode(id: 1, title: "Podcast", description: nil, audioURL: URL(string: "https://example.com/audio.mp3"),
                durationSeconds: 600, publishedAt: nil, link: nil, progressRevision: revision)
    }

    @Test func exactRetriesSurviveDiskRecreationAndPreserveNewerSamples() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PodcastProgressJournal(store: FilePodcastProgressStorage(directory: directory))
        let playback = UUID()
        try journal.start(owner: owner, episodeID: 1, playbackID: playback, revision: owner, sample: .init(seconds: 0, completed: false))
        try journal.record(owner: owner, episodeID: 1, playbackID: playback, sample: .init(seconds: 20, completed: false))
        let original = try #require(journal.entries(owner: owner).first?.pending)
        do {
            try await journal.flush(owner: owner, valid: { true }, send: { _, report in
                #expect(report == original); throw URLError(.networkConnectionLost)
            })
            Issue.record("Expected lost response")
        } catch is URLError { }
        try journal.record(owner: owner, episodeID: 1, playbackID: playback, sample: .init(seconds: 50, completed: false))
        let reopened = PodcastProgressJournal(store: FilePodcastProgressStorage(directory: directory))
        #expect(reopened.overlay(episode(owner), owner: owner).positionSeconds == 50)
        try await reopened.flush(owner: owner, valid: { true }, send: { _, report in
            #expect(report == original)
            return .init(episode: episode(next), acceptedRevision: next)
        })
        let followup = try #require(reopened.entries(owner: owner).first?.pending)
        #expect(followup.requestID != original.requestID)
        #expect(followup.expectedRevision == next)
        #expect(followup.seconds == 50)
        try await reopened.flush(owner: owner, valid: { true }, send: { _, report in
            #expect(report == followup)
            return .init(episode: episode(newer), acceptedRevision: newer)
        })
        #expect(try reopened.entries(owner: owner).first?.pending == nil)
    }

    @Test func conflictsAndFilingCannotReplayAnOlderClock() async throws {
        for filingDuringUpload in [true, false] {
            let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = PodcastProgressJournal(store: FilePodcastProgressStorage(directory: directory))
            let playback = UUID()
            try journal.start(owner: owner, episodeID: 1, playbackID: playback, revision: owner, sample: .init(seconds: 0, completed: false))
            try journal.record(owner: owner, episodeID: 1, playbackID: playback, sample: .init(seconds: 600, completed: true))
            #expect(try !journal.record(owner: owner, episodeID: 1, playbackID: playback, sample: .init(seconds: 599, completed: false)))
            try await journal.flush(owner: owner, valid: { true }, send: { _, _ in
                if filingDuringUpload { try journal.block(owner: owner, episodeIDs: [1]) }
                return .init(episode: episode(newer), acceptedRevision: next)
            })
            #expect(try journal.entries(owner: owner).first?.blocked == true)
            #expect(try journal.entries(owner: owner).first?.pending == nil)
        }
    }

    @Test func sessionChangeCannotAcknowledgeAnotherAccountsQueue() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PodcastProgressJournal(store: FilePodcastProgressStorage(directory: directory)); let playback = UUID()
        try journal.start(owner: owner, episodeID: 1, playbackID: playback, revision: owner, sample: .init(seconds: 0, completed: false))
        try journal.record(owner: owner, episodeID: 1, playbackID: playback, sample: .init(seconds: 10, completed: false))
        var valid = true
        do {
            try await journal.flush(owner: owner, valid: { valid }, send: { _, _ in
                valid = false; return .init(episode: episode(next), acceptedRevision: next)
            })
            Issue.record("Expected cancellation")
        } catch is CancellationError { }
        #expect(try journal.entries(owner: owner).first?.pending != nil)
        #expect(try journal.entries(owner: next).isEmpty)
    }
}
