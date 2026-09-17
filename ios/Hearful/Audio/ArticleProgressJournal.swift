import Foundation

nonisolated struct ArticleProgressSample: Codable, Equatable, Sendable {
    let textVersion: String
    let contentID: Int?
    let offsetUTF16: Int
    let completed: Bool

    var isValid: Bool {
        isProgressToken(textVersion) && offsetUTF16 >= 0 && (contentID == nil || contentID! > 0)
    }
    func report(revision: String) -> ArticleProgressReport {
        ArticleProgressReport(requestID: UUID().uuidString, expectedRevision: revision,
            textVersion: textVersion, contentID: contentID, offsetUTF16: offsetUTF16, completed: completed)
    }
}

nonisolated struct QueuedArticleProgress: Codable, Equatable, Sendable {
    let episodeID: Int
    let playbackID: UUID
    var revision: String
    var latest: ArticleProgressSample
    var pending: ArticleProgressReport?
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
protocol ArticleProgressStorage {
    func read(owner: String) throws -> [QueuedArticleProgress]
    func write(owner: String, entries: [QueuedArticleProgress]) throws
}

/// Account/session fingerprints and text coordinates only, excluded from backup.
/// A malformed journal is preserved and rejected rather than forgetting its guards.
@MainActor
final class FileArticleProgressStorage: ArticleProgressStorage {
    static let shared = FileArticleProgressStorage()
    let directory: URL
    private struct Envelope: Codable {
        let schema: Int
        let owner: String
        let entries: [QueuedArticleProgress]
    }
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "ArticleProgress", directoryHint: .isDirectory)) {
        self.directory = directory
    }
    private func file(_ owner: String) throws -> URL {
        guard isProgressToken(owner) else { throw CocoaError(.fileReadCorruptFile) }
        return directory.appending(path: owner + ".json")
    }
    func read(owner: String) throws -> [QueuedArticleProgress] {
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
    func write(owner: String, entries: [QueuedArticleProgress]) throws {
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
final class ArticleProgressJournal {
    static let shared = ArticleProgressJournal()
    private let store: any ArticleProgressStorage
    private var sending = false
    init(store: any ArticleProgressStorage = FileArticleProgressStorage.shared) { self.store = store }

    func entries(owner: String) throws -> [QueuedArticleProgress] { try store.read(owner: owner) }
    func clear(owner: String) throws { try store.write(owner: owner, entries: []) }
    func start(owner: String, episodeID: Int, playbackID: UUID, progress: ArticleProgressState,
               sample: ArticleProgressSample) throws {
        guard progress.isValid, sample.textVersion == progress.textVersion, sample.contentID == progress.contentID
        else { throw CocoaError(.fileWriteUnknown) }
        var rows = try entries(owner: owner)
        let old = rows.first { $0.episodeID == episodeID }
        let next = QueuedArticleProgress(episodeID: episodeID, playbackID: playbackID, revision: progress.revision,
            latest: sample, pending: old?.pending, pendingPlaybackID: old?.pendingPlaybackID,
            guards: old?.guards ?? [])
        rows.removeAll { $0.episodeID == episodeID }; rows.append(next)
        try store.write(owner: owner, entries: rows)
    }
    @discardableResult
    func record(owner: String, episodeID: Int, playbackID: UUID, sample: ArticleProgressSample) throws -> Bool {
        var rows = try entries(owner: owner)
        guard let index = rows.firstIndex(where: { $0.episodeID == episodeID && $0.playbackID == playbackID && !$0.blocked && $0.guards.isEmpty })
        else { return false }
        var row = rows[index]
        guard row.latest.textVersion == sample.textVersion, row.latest.contentID == sample.contentID,
            !(row.sampled && row.latest.completed && !sample.completed) else { return false }
        row.latest = sample; row.sampled = true
        if row.pending == nil { row.pending = sample.report(revision: row.revision); row.pendingPlaybackID = playbackID }
        rows[index] = row
        try store.write(owner: owner, entries: rows)
        return true
    }
    func resume(owner: String, episodeID: Int, progress: ArticleProgressState) throws -> ArticleProgressSample? {
        try entries(owner: owner).first {
            $0.episodeID == episodeID && !$0.blocked && $0.guards.isEmpty && $0.sampled && $0.revision == progress.revision
                && $0.latest.textVersion == progress.textVersion && $0.latest.contentID == progress.contentID
        }?.latest
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
               send: (Int, ArticleProgressReport) async throws -> ArticleProgressReceipt,
               applied: (ArticleProgressReceipt) -> Void = { _ in }) async throws {
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
            guard receipt.episode.id == entry.episodeID, receipt.progress.isValid else { throw CocoaError(.fileReadCorruptFile) }
            var rows = try entries(owner: owner)
            guard let index = rows.firstIndex(where: { $0.episodeID == entry.episodeID && $0.pending?.requestID == request.requestID && !$0.blocked })
            else { continue }
            var row = rows[index]
            let freshIntent = row.playbackID != row.pendingPlaybackID && row.revision == receipt.progress.revision
                && row.latest.textVersion == receipt.progress.textVersion && row.latest.contentID == receipt.progress.contentID
            if receipt.changedSinceAcceptance && !freshIntent {
                row.blocked = true; row.pending = nil; row.pendingPlaybackID = nil
            } else {
                let revision = row.playbackID == row.pendingPlaybackID || row.revision == request.expectedRevision
                    ? receipt.progress.revision : row.revision
                let newer = row.sampled && (row.playbackID != row.pendingPlaybackID || row.latest != ArticleProgressSample(
                    textVersion: request.textVersion, contentID: request.contentID, offsetUTF16: request.offsetUTF16, completed: request.completed))
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
