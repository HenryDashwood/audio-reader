import AppIntents
import Foundation

enum MagpieDestination: String, AppEnum {
    case latest, following, nowPlaying, shortcuts
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Destination")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .latest: "Latest", .following: "Following", .nowPlaying: "Now Playing",
        .shortcuts: "Siri and Shortcuts",
    ]
}

@MainActor
enum ShortcutNavigation {
    enum Route { case destination(MagpieDestination), episode(Episode), show(Show) }
    static var viewedEpisodeID: Int?
    private static var pending: Route?
    static func request(_ route: Route) {
        pending = route
        NotificationCenter.default.post(name: .hearfulShortcutNavigation, object: nil)
    }
    static func consume() -> Route? {
        defer { pending = nil }
        return pending
    }
    static func clear() {
        pending = nil
        viewedEpisodeID = nil
    }
}

extension Notification.Name {
    nonisolated static let hearfulShortcutNavigation = Notification.Name("hearfulShortcutNavigation")
}

struct OpenMagpieDestinationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Magpie Destination"
    static let supportedModes: IntentModes = .foreground(.immediate)
    @Parameter(title: "Destination", default: .latest) var destination: MagpieDestination
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$destination)") }
    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutNavigation.request(.destination(destination))
        return .result()
    }
}

struct OpenListeningItemIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Listening Item"
    static let supportedModes: IntentModes = .foreground(.immediate)
    @Parameter(title: "Item") var target: EpisodeEntity
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }
    @MainActor
    func perform() async throws -> some IntentResult {
        do {
            ShortcutNavigation.request(.episode(try await ShortcutLibrary.shared.episode(id: target.id)))
            return .result()
        } catch { throw ShortcutFailure.explaining(error) }
    }
}

struct OpenShowIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Show or Publication"
    static let supportedModes: IntentModes = .foreground(.immediate)
    @Parameter(title: "Show") var target: ShowEntity
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }
    @MainActor
    func perform() async throws -> some IntentResult {
        do {
            guard let show = try await ShortcutLibrary.shared.shows().first(where: { $0.id == target.id })
            else {
                throw ShortcutFailure(message: "You no longer follow that show or publication.")
            }
            ShortcutNavigation.request(.show(show))
            return .result()
        } catch { throw ShortcutFailure.explaining(error) }
    }
}
