import AppIntents
import Foundation

/// How Siri refers to one of her subscribed shows or publications.
///
/// Subscriptions are a short, stable list — exactly what Siri can match
/// spoken words against inside a phrase like "play the latest ⟨show⟩ on
/// Hearful". (Free text can never appear in a phrase; whole libraries of
/// episode titles are too big to match. A subscription list is the sweet
/// spot.)
struct ShowEntity: AppEntity {
    let id: Int
    let title: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Show")
    static let defaultQuery = ShowQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: Int, title: String) {
        self.id = id
        self.title = title
    }

    init(_ show: Show) {
        self.init(id: show.id, title: show.title)
    }
}

struct ShowQuery: EntityStringQuery {
    /// Siri asks for these when restoring a show it resolved earlier.
    func entities(for identifiers: [Int]) async throws -> [ShowEntity] {
        guard HearfulAPI.tokenProvider() != nil else { return [] }
        let api = HearfulAPI()
        let shows = (try? await api.shows()) ?? []
        return shows.filter { identifiers.contains($0.id) }.map(ShowEntity.init)
    }

    /// Spoken text from Siri's follow-up question, matched loosely against
    /// her subscriptions: "average joe" should find "An Average Joe".
    func entities(matching string: String) async throws -> [ShowEntity] {
        let api = HearfulAPI()
        let shows = try await api.shows()
        let spoken = Self.normalise(string)
        guard !spoken.isEmpty else { return [] }
        return shows.filter { show in
            let title = Self.normalise(show.title)
            return title.contains(spoken) || spoken.contains(title)
                || spoken.split(separator: " ").allSatisfy { title.contains($0) }
        }.map(ShowEntity.init)
    }

    /// The names Siri matches phrase parameters against. The system fetches
    /// these in the background, possibly before she has ever signed in; an
    /// empty list is right then, a thrown error is noise.
    func suggestedEntities() async throws -> [ShowEntity] {
        guard HearfulAPI.tokenProvider() != nil else { return [] }
        let api = HearfulAPI()
        return try await api.shows().map(ShowEntity.init)
    }

    private static func normalise(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
