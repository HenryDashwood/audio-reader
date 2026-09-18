import Combine
import Foundation
import SwiftUI

/// Filing uses the backend's existing idempotent action receipts. Persist the
/// request before sending, and replay in order after a lost acknowledgement.
@MainActor
final class OfflineLibraryActions: ObservableObject {
    static let shared = OfflineLibraryActions()
    struct Entry: Codable, Equatable {
        let requestID: String
        let action: String
        let episode: Episode
        var undoRequestID: String? = nil
        var wasInLatest: Bool? = nil
    }
    private struct Envelope: Codable { let owner: String; let entries: [Entry] }
    @Published private(set) var pending: [Entry] = []
    @Published private(set) var error: String?
    private let directory: URL
    private let api: HearfulAPIProtocol
    private let scope: () -> String?
    private let cache: OfflineCache
    private let blockProgress: (String, Int) throws -> Void
    private var owner: String?
    private var upload: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var schedule = OfflineRetrySchedule()

    init(api: HearfulAPIProtocol = HearfulAPI(),
         directory: URL = URL.applicationSupportDirectory.appending(path: "LibraryActions"),
         scope: @escaping () -> String? = { ShortcutScope.current },
         cache: OfflineCache = .shared,
         blockProgress: @escaping (String, Int) throws -> Void = { owner, id in
             try ArticleProgressJournal.shared.block(owner: owner, episodeIDs: [id])
             try PodcastProgressJournal.shared.block(owner: owner, episodeIDs: [id])
         }) {
        self.api = api; self.directory = directory; self.scope = scope; self.cache = cache; self.blockProgress = blockProgress
        subscription = NotificationCenter.default.publisher(for: .hearfulRetryOffline).sink { [weak self] note in
            MainActor.assumeIsolated { self?.retry(force: note.object as? Bool == true) }
        }
    }

    private func activate() throws -> String {
        guard let key = scope(), isProgressToken(key) else { throw CaptureInbox.InboxError.signedOut }
        if owner != key {
            upload?.cancel(); upload = nil
            pending = []; owner = nil
            let file = directory.appending(path: key + ".json")
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                guard saved.owner == key, saved.entries.allSatisfy({
                    ["mark_played", "dismiss", "restore", "undo"].contains($0.action) && $0.episode.id > 0
                        && UUID(uuidString: $0.requestID) != nil
                }) else { throw CocoaError(.fileReadCorruptFile) }
                pending = saved.entries
            }
            owner = key
        }
        return key
    }
    private func save(_ entries: [Entry], owner: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Envelope(owner: owner, entries: entries))
        try data.write(to: directory.appending(path: owner + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        pending = entries
    }

    func enqueue(_ filing: EpisodeFiling, episode: Episode) throws {
        let key = try activate()
        // Old clocks must be retired before the filing could reach the server,
        // including when its successful reply is lost.
        try blockProgress(key, episode.id)
        let action = filing == .played ? "mark_played" : filing == .dismissed ? "dismiss" : "restore"
        try save(pending + [Entry(requestID: UUID().uuidString, action: action, episode: episode,
            wasInLatest: cache.load([Episode].self, for: .recentEpisodes)?.contains { $0.id == episode.id } == true)], owner: key)
        error = nil
        applyToCache(episodeID: episode.id)
        filing.broadcast(episodeID: episode.id)
        retry(force: true)
    }

    func undo() throws {
        let key = try activate()
        guard let last = pending.last, last.action != "undo" else { return }
        try save(pending + [Entry(requestID: UUID().uuidString, action: "undo", episode: last.episode, undoRequestID: last.requestID, wasInLatest: last.wasInLatest)], owner: key)
        if last.wasInLatest == true {
            var latest = cache.load([Episode].self, for: .recentEpisodes) ?? []
            if !latest.contains(where: { $0.id == last.episode.id }) {
                latest.insert(last.episode, at: 0)
                cache.save(latest, for: .recentEpisodes)
            }
        }
        applyToCache(episodeID: last.episode.id)
        NotificationCenter.default.post(name: .hearfulSavedChanged, object: nil)
        NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
        retry(force: true)
    }

    func overlay(_ episodes: [Episode]) -> [Episode] {
        guard (try? activate()) != nil else { return episodes }
        return episodes.map { episode in
            pending.filter { $0.episode.id == episode.id && $0.episode.contentID == episode.contentID }
                .reduce(episode) { value, entry in
                    var result = value
                    switch entry.action {
                    case "mark_played": result.completed = true
                    case "dismiss": result.dismissed = true
                    case "restore": result.completed = false; result.dismissed = false; result.positionSeconds = 0; result.articleBookmark = nil
                    case "undo": result.completed = entry.episode.completed; result.dismissed = entry.episode.dismissed
                        result.positionSeconds = entry.episode.positionSeconds; result.articleBookmark = entry.episode.articleBookmark
                    default: break
                    }
                    return result
                }
        }
    }

    private func applyToCache(episodeID: Int) {
        let keys: [OfflineCache.Key] = [.recentEpisodes, .savedArticles]
            + (cache.load([Show].self, for: .shows) ?? []).map { .episodes(showID: $0.id) }
        for key in keys {
            if let episodes = cache.load([Episode].self, for: key) { cache.save(overlay(episodes), for: key) }
        }
    }

    func retry(force: Bool = false) {
        if force { schedule.reset() }
        guard schedule.isDue, upload == nil, let key = try? activate(), !pending.isEmpty else { return }
        upload = Task { [weak self] in
            guard let self else { return }
            defer { if owner == key { upload = nil } }
            do {
                while scope() == key, !Task.isCancelled, let entry = pending.first {
                    let response: CommandResponse
                    do {
                        response = try await api.offlineLibraryAction(entry.action,
                            episodeID: entry.episode.id, contentID: entry.episode.contentID,
                            requestID: entry.requestID, undoRequestID: entry.undoRequestID)
                    } catch let failure as APIError where failure.statusCode == 409 {
                        guard scope() == key, !Task.isCancelled else { return }
                        try reject(entry, message: failure.spokenResponse, owner: key)
                        continue
                    }
                    guard scope() == key, !Task.isCancelled else { return }
                    guard response.action.filing != nil, response.episode?.id == entry.episode.id else {
                        try reject(entry, message: response.spokenResponse, owner: key)
                        continue
                    }
                    try save(Array(pending.dropFirst()), owner: key)
                    error = nil
                    schedule.reset()
                    NotificationCenter.default.post(name: .hearfulSavedChanged, object: nil)
                    NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
                }
            } catch {
                guard scope() == key, !Task.isCancelled else { return }
                schedule.failed()
                if (error as? APIError)?.statusCode == 404 {
                    self.error = "Changes are saved on this device. Sync needs the updated Magpie service."
                } else {
                    self.error = (error as? APIError)?.spokenResponse ?? "Changes are saved on this device and will sync when connected."
                }
            }
        }
    }

    private func reject(_ entry: Entry, message: String, owner: String) throws {
        try save(pending.filter { $0.requestID != entry.requestID && $0.undoRequestID != entry.requestID }, owner: owner)
        // Remove this rejected optimistic state even if the next refresh also
        // fails. Preserve newer pending intents and any replacement content.
        let keys: [OfflineCache.Key] = [.recentEpisodes, .savedArticles]
            + (cache.load([Show].self, for: .shows) ?? []).map { .episodes(showID: $0.id) }
        for key in keys {
            guard var episodes = cache.load([Episode].self, for: key) else { continue }
            episodes = episodes.map { episode in
                guard episode.id == entry.episode.id, episode.contentID == entry.episode.contentID else { return episode }
                var restored = episode
                restored.completed = entry.episode.completed
                restored.dismissed = entry.episode.dismissed
                restored.positionSeconds = entry.episode.positionSeconds
                restored.articleBookmark = entry.episode.articleBookmark
                return restored
            }
            if key == .recentEpisodes, entry.wasInLatest == true,
               !episodes.contains(where: { $0.id == entry.episode.id }) {
                episodes.insert(entry.episode, at: 0)
            }
            cache.save(overlay(episodes), for: key)
        }
        OfflineSyncStatus.shared.report(message)
        // Optimistic flags are no longer authoritative. Fetch them again rather
        // than allowing a rejected local intent to look successfully synced.
        NotificationCenter.default.post(name: .hearfulSavedChanged, object: nil)
        NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
    }

    func waitForUpload() async { await upload?.value }
    func clear() {
        upload?.cancel(); upload = nil; owner = nil; pending = []; error = nil; schedule.reset()
        try? FileManager.default.removeItem(at: directory)
    }
}

struct PendingLibraryChanges: View {
    @ObservedObject private var actions = OfflineLibraryActions.shared
    var body: some View {
        if !actions.pending.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(actions.error ?? "Library changes saved on this device · Waiting to sync")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Retry sync") { actions.retry(force: true) }
                    if actions.pending.last?.action != "undo" {
                        Button("Undo last change") {
                            do { try actions.undo() }
                            catch { OfflineSyncStatus.shared.report("The change could not be undone. Please try again.") }
                        }
                    }
                }
            }
        }
    }
}
