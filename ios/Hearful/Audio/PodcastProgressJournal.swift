import Foundation

nonisolated struct PodcastProgressSample: Codable, Equatable, Sendable {
    let seconds: Double
    let completed: Bool
    var isValid: Bool { seconds.isFinite && seconds >= 0 }
    func report(revision: String) -> PodcastProgressReport {
        PodcastProgressReport(requestID: UUID().uuidString, expectedRevision: revision,
                              seconds: seconds, completed: completed)
    }
}

nonisolated struct QueuedPodcastProgress: Codable, Equatable, Sendable {
    let episodeID: Int
    let playbackID: UUID
    var revision: String
    var latest: PodcastProgressSample
    var pending: PodcastProgressReport?
    var pendingPlaybackID: UUID?
    var sampled = false
    var blocked = false
    var guards: Set<String> = []

    var isValid: Bool {
        episodeID > 0 && isProgressToken(revision) && latest.isValid
            && (pending == nil) == (pendingPlaybackID == nil)
            && (pending?.isValid ?? true) && guards.allSatisfy { !$0.isEmpty }
    }
}

@MainActor
protocol PodcastProgressStorage {
    func read(owner: String) throws -> [QueuedPodcastProgress]
    func write(owner: String, entries: [QueuedPodcastProgress]) throws
}

/// Account/session fingerprints and podcast positions only, excluded from backup.
/// A malformed journal is preserved and rejected rather than forgetting its guards.
@MainActor
final class FilePodcastProgressStorage: PodcastProgressStorage {
    static let shared = FilePodcastProgressStorage()
    let directory: URL
    private struct Envelope: Codable {
        let schema: Int
        let owner: String
        let entries: [QueuedPodcastProgress]
    }
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "PodcastProgress", directoryHint: .isDirectory)) {
        self.directory = directory
    }
    private func file(_ owner: String) throws -> URL {
        guard isProgressToken(owner) else { throw CocoaError(.fileReadCorruptFile) }
        return directory.appending(path: owner + ".json")
    }
    func read(owner: String) throws -> [QueuedPodcastProgress] {
        let url = try file(owner)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.schema == 1, value.owner == owner, value.entries.allSatisfy(\.isValid),
            Set(value.entries.map(\.episodeID)).count == value.entries.count
        else { throw CocoaError(.fileReadCorruptFile) }
        return value.entries
    }
    func write(owner: String, entries: [QueuedPodcastProgress]) throws {
        let url = try file(owner)
        guard entries.allSatisfy(\.isValid), Set(entries.map(\.episodeID)).count == entries.count
        else { throw CocoaError(.fileWriteUnknown) }
        if entries.isEmpty {
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile { }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let data = try JSONEncoder().encode(Envelope(schema: 1, owner: owner, entries: entries))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func clearAll() throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch CocoaError.fileNoSuchFile { }
    }
}

/// Main-actor disk transactions are synchronous and small. No transaction spans
/// a network suspension, so filing/sign-out can invalidate an in-flight reply.
@MainActor
final class PodcastProgressJournal {
    static let shared = PodcastProgressJournal()
    private let store: any PodcastProgressStorage
    private var sending = false
    init(store: any PodcastProgressStorage = FilePodcastProgressStorage.shared) { self.store = store }

    func entries(owner: String) throws -> [QueuedPodcastProgress] { try store.read(owner: owner) }
    func clear(owner: String) throws { try store.write(owner: owner, entries: []) }
    func start(owner: String, episodeID: Int, playbackID: UUID, revision: String,
               sample: PodcastProgressSample) throws {
        guard isProgressToken(revision), sample.isValid
        else { throw CocoaError(.fileWriteUnknown) }
        var rows = try entries(owner: owner)
        let old = rows.first { $0.episodeID == episodeID }
        let next = QueuedPodcastProgress(episodeID: episodeID, playbackID: playbackID, revision: revision,
            latest: sample, pending: old?.pending, pendingPlaybackID: old?.pendingPlaybackID,
            guards: old?.guards ?? [])
        rows.removeAll { $0.episodeID == episodeID }; rows.append(next)
        try store.write(owner: owner, entries: rows)
    }
    @discardableResult
    func record(owner: String, episodeID: Int, playbackID: UUID, sample: PodcastProgressSample) throws -> Bool {
        var rows = try entries(owner: owner)
        guard let index = rows.firstIndex(where: { $0.episodeID == episodeID && $0.playbackID == playbackID && !$0.blocked && $0.guards.isEmpty })
        else { return false }
        var row = rows[index]
        guard sample.isValid, !(row.sampled && row.latest.completed && !sample.completed) else { return false }
        row.latest = sample; row.sampled = true
        if row.pending == nil { row.pending = sample.report(revision: row.revision); row.pendingPlaybackID = playbackID }
        rows[index] = row
        try store.write(owner: owner, entries: rows)
        return true
    }
    func resume(owner: String, episodeID: Int, revision: String) throws -> PodcastProgressSample? {
        try entries(owner: owner).first {
            $0.episodeID == episodeID && !$0.blocked && $0.guards.isEmpty && $0.sampled && $0.revision == revision
        }?.latest
    }
    func overlay(_ episode: Episode, owner: String) -> Episode {
        guard episode.audioURL != nil, let revision = episode.progressRevision,
              let local = try? resume(owner: owner, episodeID: episode.id, revision: revision) else { return episode }
        var result = episode
        result.positionSeconds = local.seconds
        result.completed = local.completed
        return result
    }

    func block(owner: String, episodeIDs: Set<Int>) throws {
        var rows = try entries(owner: owner)
        for index in rows.indices where episodeIDs.contains(rows[index].episodeID) {
            rows[index].blocked = true; rows[index].pending = nil; rows[index].pendingPlaybackID = nil
        }
        try store.write(owner: owner, entries: rows)
    }
    func hold(owner: String, episodeIDs: Set<Int>, requestID: String) throws {
        var rows = try entries(owner: owner)
        for index in rows.indices where episodeIDs.contains(rows[index].episodeID) { rows[index].guards.insert(requestID) }
        try store.write(owner: owner, entries: rows)
    }
    func confirm(owner: String, requestID: String) throws {
        var rows = try entries(owner: owner)
        for index in rows.indices { rows[index].guards.remove(requestID) }
        try store.write(owner: owner, entries: rows)
    }

    /// Exact retries stay at the head; only this request's own acknowledgement
    /// can advance its later samples. A stale reply never rebases an old clock.
    func flush(owner: String, valid: () -> Bool,
               send: (Int, PodcastProgressReport) async throws -> PodcastProgressReceipt,
               applied: (PodcastProgressReceipt) -> Void = { _ in }) async throws {
        guard !sending else { return }
        sending = true; defer { sending = false }
        try check(valid)
        let pending = try entries(owner: owner).filter { !$0.blocked && $0.guards.isEmpty && $0.pending != nil }
        for entry in pending {
            try check(valid)
            guard let request = entry.pending,
                try entries(owner: owner).contains(where: { $0.episodeID == entry.episodeID && $0.pending?.requestID == request.requestID && !$0.blocked && $0.guards.isEmpty })
            else { continue }
            let receipt = try await send(entry.episodeID, request)
            try check(valid)
            guard receipt.episode.id == entry.episodeID, receipt.episode.progressRevision.map(isProgressToken) == true else { throw CocoaError(.fileReadCorruptFile) }
            var rows = try entries(owner: owner)
            guard let index = rows.firstIndex(where: { $0.episodeID == entry.episodeID && $0.pending?.requestID == request.requestID && !$0.blocked })
            else { continue }
            var row = rows[index]
            let freshIntent = row.playbackID != row.pendingPlaybackID && row.revision == receipt.episode.progressRevision!
            if receipt.changedSinceAcceptance && !freshIntent {
                row.blocked = true; row.pending = nil; row.pendingPlaybackID = nil
            } else {
                let revision = row.playbackID == row.pendingPlaybackID || row.revision == request.expectedRevision
                    ? receipt.episode.progressRevision! : row.revision
                let newer = row.sampled && (row.playbackID != row.pendingPlaybackID || row.latest != PodcastProgressSample(
                    seconds: request.seconds, completed: request.completed))
                row.revision = revision
                row.pending = newer ? row.latest.report(revision: revision) : nil
                row.pendingPlaybackID = newer ? row.playbackID : nil
            }
            rows[index] = row
            try store.write(owner: owner, entries: rows)
            applied(receipt)
        }
    }
    private func check(_ valid: () -> Bool) throws {
        try Task.checkCancellation()
        guard valid() else { throw CancellationError() }
    }
}
