import AppIntents
import Foundation

struct FindListeningItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Listening Items"
    static let description = IntentDescription(
        "Searches your library. With no search or show, returns items from Latest.")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Show or publication") var show: ShowEntity?
    @Parameter(title: "Unheard only", default: false) var unheardOnly: Bool
    @Parameter(title: "Maximum duration", unit: .minutes, supportsNegativeNumbers: false) var maximumMinutes:
        Measurement<UnitDuration>?
    @Parameter(title: "Maximum results", default: 20) var limit: Int
    static var parameterSummary: some ParameterSummary {
        Summary("Find items matching \(\.$search)") {
            \.$show
            \.$unheardOnly
            \.$maximumMinutes
            \.$limit
        }
    }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[EpisodeEntity]> {
        guard (1...100).contains(limit) else {
            throw ShortcutFailure(message: "Choose between one and one hundred results.")
        }
        if let maximumMinutes {
            _ = try ListeningControls.seconds(maximumMinutes.converted(to: .seconds).value)
        }
        do {
            let items = try await ShortcutLibrary.shared.find(search, showID: show?.id)
            let selected = Self.filter(
                items, unheard: unheardOnly, maximumMinutes: maximumMinutes?.converted(to: .minutes).value,
                limit: limit)
            return .result(value: selected.map(EpisodeEntity.init))
        } catch { throw ShortcutFailure.explaining(error) }
    }
    static func filter(_ items: [Episode], unheard: Bool, maximumMinutes: Double?, limit: Int) -> [Episode] {
        Array(
            items.filter { item in
                if unheard && item.completed == true { return false }
                if let maximumMinutes {
                    guard let duration = item.durationSeconds, duration > 0,
                        Double(duration) <= maximumMinutes * 60
                    else { return false }
                }
                return true
            }.prefix(max(0, limit)))
    }
}

struct GetNewsletterAddressIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Newsletter Address"
    static let supportedModes: IntentModes = .background
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let address = try await HearfulAPI().newsletterAddress().address
            return .result(
                value: address, dialog: IntentDialog("Your Magpie newsletter address is \(address)."))
        } catch { throw ShortcutFailure.explaining(error) }
    }
}

enum ItemFilingChoice: String, AppEnum {
    case played, dismissed, restored
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Filing")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .played: "Mark played or read", .dismissed: "Dismiss", .restored: "Mark unplayed or unread",
    ]
    var action: String { self == .played ? "mark_played" : self == .dismissed ? "dismiss" : "restore" }
    var filing: EpisodeFiling { self == .played ? .played : self == .dismissed ? .dismissed : .restored }
}

struct FileListeningItemIntent: AppIntent {
    static let title: LocalizedStringResource = "File a Listening Item"
    static let description = IntentDescription(
        "Marks an item played, dismisses it, or restores it. Leave Item empty to use the current item.")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Action", requestValueDialog: "Mark played, dismiss, or restore?") var action: ItemFilingChoice
    @Parameter(title: "Item") var item: EpisodeEntity?
    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) \(\.$item)") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EpisodeEntity> & ProvidesDialog {
        do {
            let id = item?.id ?? PlaybackCoordinator.shared.currentEpisode?.id
            guard let id else { throw ShortcutFailure(message: "Choose an item, or start listening first.") }
            ShortcutUndo.clear()
            let response = try await ShortcutActionExecution.shared.run(action.action, episodeID: id)
            guard let episode = response.episode else {
                throw ShortcutFailure(message: response.spokenResponse)
            }
            CommandExecution.broadcast(response, player: PlaybackCoordinator.shared)
            return .result(
                value: EpisodeEntity(episode),
                dialog: IntentDialog("\(action.filing.confirmation(for: episode))"))
        } catch { throw ShortcutFailure.explaining(error) }
    }
}

struct UndoMagpieActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Undo Last Magpie Action"
    static let supportedModes: IntentModes = .background
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            if try ShortcutUndo.undoSpeed() {
                return .result(value: "Playback speed restored.", dialog: "Playback speed restored.")
            }
            let response = try await ShortcutActionExecution.shared.run("undo", episodeID: nil)
            guard response.action != .unknown else { throw ShortcutFailure(message: response.spokenResponse) }
            CommandExecution.broadcast(response, player: PlaybackCoordinator.shared)
            return .result(value: response.spokenResponse, dialog: IntentDialog("\(response.spokenResponse)"))
        } catch { throw ShortcutFailure.explaining(error) }
    }
}

struct FollowPublicationURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Follow a Publication URL"
    static let description = IntentDescription(
        "Finds and follows a podcast or publication feed from a web address.")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "URL") var url: URL
    @Parameter(title: "Feed") var feed: String?
    static var parameterSummary: some ParameterSummary { Summary("Follow publication at \(\.$url)") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ShowEntity> & ProvidesDialog {
        do {
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw ShortcutFailure(message: "Choose a website address beginning with https or http.")
            }
            let api = HearfulAPI()
            let discovered = try await api.discoverFeeds(url: url)
            guard !discovered.candidates.isEmpty else {
                throw ShortcutFailure(message: "I could not find a feed at that address.")
            }
            let chosen: FeedDiscoveryCandidate
            if discovered.candidates.count == 1 {
                chosen = discovered.candidates[0]
            } else {
                let choices = discovered.candidates.map { "\($0.title) — \($0.feedURL.absoluteString)" }
                let selected = try await $feed.requestDisambiguation(
                    among: choices, dialog: "Which feed would you like to follow?")
                guard let index = choices.firstIndex(of: selected) else { throw CancellationError() }
                chosen = discovered.candidates[index]
            }
            ShortcutUndo.clear()
            let show = try await api.subscribe(feedURL: chosen.feedURL)
            ShortcutLibrary.shared.invalidate()
            HearfulShortcuts.updateAppShortcutParameters()
            NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
            return .result(value: ShowEntity(show), dialog: IntentDialog("Following \(show.title)."))
        } catch { throw ShortcutFailure.explaining(error) }
    }
}
