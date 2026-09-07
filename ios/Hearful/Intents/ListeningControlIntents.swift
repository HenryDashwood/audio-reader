import AppIntents
import Foundation

struct ContinueListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Resumes your last podcast or article from your saved place.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EpisodeEntity> & ProvidesDialog {
        do {
            let episode = try await ShortcutPlayback.resolve(id: nil)
            try await ShortcutPlayback.start(episode) {
                try await continueInForeground(IntentDialog("Opening Magpie to continue listening."))
            }
            return .result(
                value: EpisodeEntity(episode), dialog: IntentDialog("Continuing \(episode.title)."))
        } catch { throw ShortcutFailure.explaining(error) }
    }
}

struct PauseListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Listening"
    static let supportedModes: IntentModes = .background
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try ListeningControls.requireItem()
        PlaybackCoordinator.shared.pause()
        return .result(dialog: "Paused.")
    }
}

enum SkipDirection: String, AppEnum {
    case forward, backward
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Direction")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .forward: "Forward", .backward: "Backward",
    ]
}

@MainActor
enum ListeningControls {
    static func requireItem(player: PlaybackCoordinator = .shared) throws {
        guard player.currentEpisode != nil else {
            throw ShortcutFailure(message: "Nothing is loaded. Ask Magpie to continue listening first.")
        }
    }

    static func seconds(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0, value <= 86400 else {
            throw ShortcutFailure(message: "Choose a duration between zero and twenty-four hours.")
        }
        return value
    }

    static func rate(_ value: Double) throws -> Float {
        guard value.isFinite, (0.5...3).contains(value) else {
            throw ShortcutFailure(message: "Choose a speed between half speed and three times speed.")
        }
        return Float(value)
    }
}

struct SkipListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip in Listening Item"
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Direction", default: .forward) var direction: SkipDirection
    @Parameter(title: "Duration", defaultValue: 30, unit: .seconds, supportsNegativeNumbers: false)
    var duration: Measurement<UnitDuration>
    static var parameterSummary: some ParameterSummary { Summary("Skip \(\.$direction) by \(\.$duration)") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        try ListeningControls.requireItem()
        let seconds = try ListeningControls.seconds(duration.converted(to: .seconds).value)
        PlaybackCoordinator.shared.skip(by: direction == .forward ? seconds : -seconds)
        return .result(value: PlaybackCoordinator.shared.currentTime, dialog: "Skipped.")
    }
}

struct SeekListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Go to Listening Position"
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Position", unit: .seconds, supportsNegativeNumbers: false) var position:
        Measurement<UnitDuration>
    static var parameterSummary: some ParameterSummary { Summary("Go to \(\.$position) in the current item") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        try ListeningControls.requireItem()
        PlaybackCoordinator.shared.seek(
            to: try ListeningControls.seconds(position.converted(to: .seconds).value))
        return .result(value: PlaybackCoordinator.shared.currentTime, dialog: "Position changed.")
    }
}

struct SetListeningSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Playback Speed"
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Speed", requestValueDialog: "What playback speed would you like?") var speed: Double
    static var parameterSummary: some ParameterSummary { Summary("Set playback speed to \(\.$speed)") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        try ListeningControls.requireItem()
        let rate = try ListeningControls.rate(speed)
        let player = PlaybackCoordinator.shared
        ShortcutUndo.rememberSpeed(player.playbackRate, applied: rate, mode: player.mode)
        player.setPlaybackRate(rate)
        return .result(value: Double(player.playbackRate), dialog: IntentDialog("\(speed) times speed."))
    }
}

struct SetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Duration", unit: .minutes, supportsNegativeNumbers: false,
        requestValueDialog: "How long would you like to listen?")
    var minutes: Measurement<UnitDuration>
    static var parameterSummary: some ParameterSummary { Summary("Stop listening after \(\.$minutes)") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Date> & ProvidesDialog {
        try ListeningControls.requireItem()
        let minutes = minutes.converted(to: .minutes).value
        guard minutes.isFinite, (1...1440).contains(minutes) else {
            throw ShortcutFailure(message: "Choose a timer between one minute and twenty-four hours.")
        }
        let rounded = Int(minutes.rounded(.up))
        SleepTimer.shared.start(minutes: rounded)
        return .result(
            value: SleepTimer.shared.endsAt!,
            dialog: IntentDialog("I will stop in \(SleepTimer.spokenDuration(minutes: rounded))."))
    }
}

struct CancelSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Sleep Timer"
    static let supportedModes: IntentModes = .background
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SleepTimer.shared.cancel()
        return .result(dialog: "Sleep timer off.")
    }
}

struct ListeningStatusEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Listening Status")
    @Property(title: "Item") var item: EpisodeEntity?
    @Property(title: "Playing") var playing: Bool
    @Property(title: "Position in seconds") var position: Double
    @Property(title: "Remaining seconds") var remaining: Double?
    @Property(title: "Speed") var speed: Double
    @Property(title: "Sleep timer ends") var timerEnd: Date?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(item?.title ?? "Nothing loaded")")
    }
    init() {
        playing = false
        position = 0
        speed = 1
    }
}

struct GetListeningStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Listening Status"
    static let supportedModes: IntentModes = .background
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ListeningStatusEntity> & ProvidesDialog {
        let player = PlaybackCoordinator.shared
        let status = ListeningStatusEntity()
        status.item = player.currentEpisode.map(EpisodeEntity.init)
        status.playing = player.isPlaying
        status.position = player.currentTime
        status.remaining = player.duration > 0 ? max(0, player.duration - player.currentTime) : nil
        status.speed = Double(player.playbackRate)
        status.timerEnd = SleepTimer.shared.endsAt
        var message =
            player.currentEpisode.map {
                "\(player.isPlaying ? "Listening to" : "Paused on") \($0.title), at \(status.speed) times speed."
            }
            ?? "Nothing is loaded in Magpie."
        if let remaining = status.remaining {
            message += " About \(Int(ceil(remaining / 60))) minutes of content remain."
        }
        if let remaining = SleepTimer.shared.remaining {
            message += " Sleep timer: \(Int(ceil(remaining / 60))) minutes left."
        }
        return .result(value: status, dialog: IntentDialog("\(message)"))
    }
}
