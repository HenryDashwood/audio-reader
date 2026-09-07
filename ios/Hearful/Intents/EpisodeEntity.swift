import AppIntents
import Foundation

/// Stable identity and discoverable metadata. Playback always resolves fresh state.
struct EpisodeEntity: AppEntity {
    let id: Int
    @Property(title: "Title") var title: String
    @Property(title: "Show or publication") var source: String
    @Property(title: "Article") var isArticle: Bool
    @Property(title: "Played or read") var isPlayed: Bool
    @Property(title: "Duration in seconds") var duration: Int?

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Listening Item")
    static let defaultQuery = EpisodeQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(source) · \(isArticle ? "Article" : "Episode")")
    }

    init(_ episode: Episode) {
        id = episode.id
        title = episode.title
        source = episode.feedTitle ?? "Magpie"
        isArticle = episode.isArticle
        isPlayed = episode.completed == true
        duration = episode.durationSeconds
    }
}

struct EpisodeQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [Int]) async throws -> [EpisodeEntity] {
        do {
            return try await ShortcutLibrary.shared.episodes(ids: identifiers).map(EpisodeEntity.init)
        } catch { throw ShortcutFailure.explaining(error) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [EpisodeEntity] {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do { return try await ShortcutLibrary.shared.find(string).map(EpisodeEntity.init) } catch {
            throw ShortcutFailure.explaining(error)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [EpisodeEntity] {
        guard ShortcutScope.current != nil else { return [] }
        // Suggestions are opportunistic. Explicit lookup above preserves errors.
        return (try? await ShortcutLibrary.shared.suggestions().map(EpisodeEntity.init)) ?? []
    }
}
