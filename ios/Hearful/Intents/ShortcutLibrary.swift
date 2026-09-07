import AppIntents
import CryptoKit
import Foundation

/// Never persist credentials. A session fingerprint also prevents cached titles
/// from another account or development server appearing in system suggestions.
nonisolated enum ShortcutScope {
    static var current: String? {
        guard let token = HearfulAPI.tokenProvider() else { return nil }
        let value = AppConfiguration.apiBaseURL.absoluteString + ":" + token
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct ShortcutFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func explaining(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? APIError { return ShortcutFailure(message: error.spokenResponse) }
        if error is VoiceTimeout {
            return ShortcutFailure(message: "Magpie took too long to respond. Please try again.")
        }
        if error is ShortcutFailure { return error }
        return ShortcutFailure(message: "Magpie could not finish that action. Please try again.")
    }
}

@MainActor
final class ShortcutLibrary {
    static let shared = ShortcutLibrary()
    private let api: HearfulAPIProtocol
    private let scope: @Sendable () -> String?
    private let directory: URL
    private var snapshot: Snapshot?
    private var loadedScope: String?

    private struct Snapshot: Codable {
        var date: Date
        var shows: [Show] = []
        var episodes: [Episode] = []
    }

    init(
        api: HearfulAPIProtocol = HearfulAPI(),
        directory: URL = URL.cachesDirectory.appending(path: "ShortcutLibrary"),
        scope: @escaping @Sendable () -> String? = { ShortcutScope.current }
    ) {
        self.api = api
        self.directory = directory
        self.scope = scope
    }

    func invalidate() {
        snapshot = nil
        loadedScope = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func session() throws -> String {
        guard let key = scope() else {
            throw ShortcutFailure(message: "Please open Magpie and sign in first.")
        }
        if key != loadedScope {
            snapshot = nil
            loadedScope = key
            if let data = try? Data(contentsOf: directory.appending(path: key)),
                let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
                Date().timeIntervalSince(saved.date) < 300
            {
                snapshot = saved
            }
        }
        if let saved = snapshot, Date().timeIntervalSince(saved.date) >= 300 { snapshot = nil }
        return key
    }

    private func check(_ key: String) throws {
        try Task.checkCancellation()
        guard scope() == key else { throw CancellationError() }
    }

    private func save(_ key: String) {
        guard let snapshot, scope() == key else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: directory.appending(path: key), options: .atomic)
        }
    }

    func shows() async throws -> [Show] {
        let key = try session()
        if let snapshot, !snapshot.shows.isEmpty { return snapshot.shows }
        let result = try await withVoiceDeadline(seconds: 12) { try await self.api.shows() }
        try check(key)
        if snapshot == nil { snapshot = Snapshot(date: Date()) }
        snapshot?.shows = result
        save(key)
        return result
    }

    func suggestions() async throws -> [Episode] {
        let key = try session()
        if let snapshot, !snapshot.episodes.isEmpty { return snapshot.episodes }
        let result = try await withVoiceDeadline(seconds: 12) { try await self.api.recentEpisodes(limit: 30) }
        try check(key)
        if snapshot == nil { snapshot = Snapshot(date: Date()) }
        snapshot?.episodes = result
        save(key)
        return result
    }

    /// Explicit searches are fresh and read-only, including repeated system queries.
    func find(_ query: String, showID: Int? = nil, latestLimit: Int = 100) async throws -> [Episode] {
        let key = try session()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await withVoiceDeadline(seconds: 12) {
            if let showID {
                return try await self.api.episodes(showID: showID, query: query.isEmpty ? nil : query)
            }
            if query.isEmpty { return try await self.api.recentEpisodes(limit: latestLimit) }
            return try await self.api.searchLibraryEpisodes(query: query)
        }
        try check(key)
        return result.filter { $0.audioURL != nil || $0.hasText == true }
    }

    /// Resolve at execution, never recreate a playable Episode from an entity.
    func episode(id: Int) async throws -> Episode {
        let key = try session()
        let result = try await withVoiceDeadline(seconds: 12) { try await self.api.episode(id: id) }
        try check(key)
        return result
    }

    func episodes(ids: [Int]) async throws -> [Episode] {
        let key = try session()
        // Batches bound concurrency while avoiding N serial network round trips.
        var result: [Episode] = []
        for start in stride(from: 0, to: ids.count, by: 4) {
            let batch = Array(ids[start..<min(start + 4, ids.count)])
            let api = self.api
            let values = try await withVoiceDeadline(seconds: 12) {
                try await withThrowingTaskGroup(of: Episode?.self) { group in
                    for id in batch {
                        group.addTask {
                            do { return try await api.episode(id: id) } catch let error as APIError
                                where error.statusCode == 404
                            { return nil }
                        }
                    }
                    var found: [Episode] = []
                    for try await episode in group { if let episode { found.append(episode) } }
                    return found
                }
            }
            try check(key)
            result += values
        }
        let byID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}
