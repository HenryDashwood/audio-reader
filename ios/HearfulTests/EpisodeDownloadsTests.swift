import Foundation
import Testing

@testable import Hearful

private func podcast(
    _ id: Int, minutes: Int = 60, show: String = "https://example.com/show.xml", completed: Bool? = nil
) -> Episode {
    var episode = Episode(
        id: id, title: "Episode \(id)", description: nil,
        audioURL: URL(string: "https://example.com/\(id).mp3"), durationSeconds: minutes * 60,
        publishedAt: nil, link: nil, completed: completed)
    episode.feedURL = URL(string: show)
    return episode
}

/// 60 minutes at the estimated bitrate.
private let hour = DownloadPolicy.estimate(podcast(0))

private func record(
    _ id: Int, origin: DownloadOrigin, bytes: Int64 = hour, playedAt: Date? = nil,
    requestedAt: Date = Date(timeIntervalSince1970: 0), status: DownloadStatus = .downloaded
) -> DownloadRecord {
    DownloadRecord(
        episode: podcast(id), origin: origin, status: status, filename: "\(id).mp3", bytes: bytes,
        requestedAt: requestedAt, playedAt: playedAt)
}

@Suite("Download limit rules")
struct DownloadPolicyTests {
    @Test func estimatesFromDurationOrFallsBack() {
        #expect(DownloadPolicy.estimate(podcast(1, minutes: 60)) == 57_600_000)
        var unknown = podcast(2)
        unknown.durationSeconds = nil
        #expect(DownloadPolicy.estimate(unknown) == DownloadPolicy.fallbackBytes)
    }

    @Test func finishedThenAutomaticAreRemovedFirstAndManualNever() {
        let records = [
            record(1, origin: .manual),
            record(2, origin: .automatic, requestedAt: Date(timeIntervalSince1970: 20)),
            record(3, origin: .automatic, requestedAt: Date(timeIntervalSince1970: 10)),
            record(4, origin: .manual, playedAt: Date(timeIntervalSince1970: 5)),
        ]
        #expect(DownloadPolicy.evictable(records, protecting: nil).map(\.id) == [4, 3, 2])
        // Whatever is in the player stays put.
        #expect(DownloadPolicy.evictable(records, protecting: 4).map(\.id) == [3, 2])
    }

    @Test func overageCountsOnlyWhatCannotBeRemoved() {
        let records = [record(1, origin: .manual), record(2, origin: .automatic)]
        // Two hours allowed: one manual hour stays, the automatic one can go.
        #expect(DownloadPolicy.overage(adding: hour, records: records, limit: 2 * hour, protecting: nil) == 0)
        #expect(DownloadPolicy.overage(adding: 2 * hour, records: records, limit: 2 * hour, protecting: nil) == hour)
        #expect(DownloadPolicy.overage(adding: 9 * hour, records: records, limit: nil, protecting: nil) == 0)
        #expect(DownloadPolicy.evictions(adding: hour, records: records, limit: 2 * hour, protecting: nil) == [2])
    }

    @Test func automaticKeepsTheNewestOfEachShowWithinTheLimit() {
        let latest = [
            podcast(10, show: "a"), podcast(11, show: "a"), podcast(20, show: "b"),
            podcast(21, show: "b", completed: true), podcast(30, show: "c"),
        ]
        var settings = DownloadSettings()
        settings.limitBytes = Int(2 * hour)
        let plan = DownloadPolicy.automaticPlan(
            latest: latest, records: [], settings: settings, protecting: nil, freeSpace: nil)
        // One per show, newest first, stopping at the limit.
        #expect(plan.start.map(\.id) == [10, 20])
        #expect(plan.remove.isEmpty)
    }

    @Test func automaticDropsWhatLeftLatestButNotManualOrPlaying() {
        let records = [
            record(1, origin: .automatic), record(2, origin: .manual), record(3, origin: .automatic),
        ]
        let plan = DownloadPolicy.automaticPlan(
            latest: [podcast(4)], records: records, settings: DownloadSettings(), protecting: 3, freeSpace: nil)
        #expect(plan.remove == [1])
        #expect(plan.start.map(\.id) == [4])
    }

    @Test func automaticMakesRoomOnlyFromFinishedEpisodes() {
        var settings = DownloadSettings()
        settings.limitBytes = Int(2 * hour)
        let records = [
            record(1, origin: .manual, playedAt: Date()), record(2, origin: .manual),
        ]
        let plan = DownloadPolicy.automaticPlan(
            latest: [podcast(5), podcast(6, show: "other")], records: records, settings: settings,
            protecting: nil, freeSpace: nil)
        #expect(plan.start.map(\.id) == [5])
        #expect(plan.remove == [1])
    }

    @Test func automaticOffRemovesEveryUnheardAutomaticDownload() {
        var settings = DownloadSettings()
        settings.automatic = false
        let plan = DownloadPolicy.automaticPlan(
            latest: [podcast(1)], records: [record(1, origin: .automatic), record(2, origin: .manual)],
            settings: settings, protecting: nil, freeSpace: nil)
        #expect(plan.start.isEmpty)
        #expect(plan.remove == [1])
    }

    @Test func automaticLeavesSpaceOnThePhone() {
        let plan = DownloadPolicy.automaticPlan(
            latest: [podcast(1)], records: [], settings: DownloadSettings(), protecting: nil,
            freeSpace: DownloadPolicy.freeSpaceMargin + hour / 2)
        #expect(plan.start.isEmpty)
    }

    @Test func finishedDownloadsExpireAfterADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let records = [
            record(1, origin: .manual, playedAt: now.addingTimeInterval(-25 * 3600)),
            record(2, origin: .manual, playedAt: now.addingTimeInterval(-3600)),
            record(3, origin: .manual),
        ]
        #expect(DownloadPolicy.expired(records, now: now, protecting: nil) == [1])
        #expect(DownloadPolicy.expired(records, now: now, protecting: 1).isEmpty)
    }

    @Test func spokenSizesAreWords() {
        #expect(spokenBytes(57_600_000) == "60 megabytes")
        #expect(spokenBytes(2_000_000_000) == "2 gigabytes")
        #expect(spokenBytes(1_000_000_000) == "1 gigabyte")
        #expect(spokenBytes(1_250_000_000) == "1.3 gigabytes")
        #expect(spokenBytes(2_000_000_000, adjective: true) == "2 gigabyte")
    }
}

@MainActor
final class FakeDownloadTransport: DownloadTransport {
    var onEvent: (@MainActor (DownloadEvent) -> Void)?
    var started: [DownloadTaskRequest] = []
    var cancelled: [Int] = []
    var cancelledAll = false
    var active: [(episodeID: Int, epoch: UUID)] = []

    func start(_ request: DownloadTaskRequest) { started.append(request) }
    func cancel(episodeID: Int) { cancelled.append(episodeID) }
    func cancelAll() { cancelledAll = true }
    func activeTasks() async -> [(episodeID: Int, epoch: UUID)] { active }
    func finishBackgroundEvents() async {}

    /// Delivers a finished file as the session delegate would.
    func finish(_ episodeID: Int, bytes: Int = 1234) throws {
        let request = try #require(started.last { $0.episodeID == episodeID })
        let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mp3")
        try Data(repeating: 1, count: bytes).write(to: file)
        onEvent?(.finished(episodeID: episodeID, epoch: request.epoch, file: file))
    }
}

@MainActor
@Suite("Episode downloads")
struct EpisodeDownloadsTests {
    final class Harness {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let transport = FakeDownloadTransport()
        var latest: [Episode] = []
        var mobileData = false
        var freeSpace: Int64? = 100_000_000_000
        var playing: Int?
        var now = Date(timeIntervalSince1970: 1_000_000)

        @MainActor
        func make() -> EpisodeDownloads {
            EpisodeDownloads(
                store: DownloadStore(directory: directory), defaults: defaults,
                makeTransport: { [transport] _ in transport },
                latest: { [unowned self] in latest }, isSignedIn: { true },
                protecting: { [unowned self] in playing }, isOnMobileData: { [unowned self] in mobileData },
                freeSpace: { [unowned self] in freeSpace }, now: { [unowned self] in now },
                observesSystem: false)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func aDownloadStartsArrivesAndSurvivesRelaunch() throws {
        let harness = Harness()
        let downloads = harness.make()
        #expect(downloads.request([podcast(1)]) == .started([podcast(1)]))
        #expect(harness.transport.started.map(\.episodeID) == [1])
        #expect(harness.transport.started[0].allowsCellular)
        #expect(downloads.localFile(for: podcast(1)) == nil)

        try harness.transport.finish(1, bytes: 4321)
        let file = try #require(downloads.localFile(for: podcast(1)))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(downloads.record(for: 1)?.bytes == 4321)

        let reopened = harness.make()
        #expect(reopened.localFile(for: podcast(1)) == file)
        #expect(reopened.record(for: 1)?.origin == .manual)
    }

    @Test func goingOverTheLimitNeedsAYesAndThenMakesRoom() async throws {
        let harness = Harness()
        harness.defaults.set(Int(hour * 2), forKey: DownloadSettings.limitKey)
        let downloads = harness.make()
        _ = downloads.request([podcast(1)])
        try harness.transport.finish(1, bytes: Int(hour))
        harness.latest = [podcast(2, show: "other")]
        // A manual hour and an automatic hour fill the limit.
        await downloads.refreshAutomatic(force: true)
        try harness.transport.finish(2, bytes: Int(hour))

        // A third hour fits by removing the automatic one: no question.
        #expect(downloads.request([podcast(3)]) == .started([podcast(3)]))
        #expect(downloads.record(for: 2) == nil)

        guard case .needsConfirmation(let confirmation) = downloads.request([podcast(4)]) else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(confirmation.overLimitBytes == hour)
        #expect(!confirmation.usesMobileData)
        #expect(confirmation.message.contains("more than your"))
        #expect(harness.transport.started.last?.episodeID == 3)
        downloads.confirm(confirmation, waitForWiFi: false)
        #expect(harness.transport.started.last?.episodeID == 4)
        // Her own unheard downloads are all kept.
        #expect(downloads.record(for: 1) != nil && downloads.record(for: 3) != nil)
    }

    @Test func mobileDataAsksAndCanWaitForWiFi() {
        let harness = Harness()
        harness.mobileData = true
        let downloads = harness.make()
        guard case .needsConfirmation(let confirmation) = downloads.request([podcast(1)]) else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(confirmation.usesMobileData)
        #expect(confirmation.spokenQuestion.contains("wait for Wi-Fi"))
        downloads.confirm(confirmation, waitForWiFi: true)
        #expect(harness.transport.started.last?.allowsCellular == false)
        #expect(downloads.record(for: 1)?.status == .queued(waitingForWiFi: true))
    }

    @Test func mobileDataIsFineWhenWiFiOnlyIsOff() {
        let harness = Harness()
        harness.mobileData = true
        harness.defaults.set(false, forKey: DownloadSettings.wifiOnlyKey)
        let downloads = harness.make()
        #expect(downloads.request([podcast(1)]) == .started([podcast(1)]))
    }

    @Test func aFullPhoneRefuses() {
        let harness = Harness()
        harness.freeSpace = DownloadPolicy.freeSpaceMargin
        let downloads = harness.make()
        guard case .refused(let message) = downloads.request([podcast(1)]) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(message.contains("not enough space"))
        #expect(harness.transport.started.isEmpty)
    }

    @Test func articlesAndDuplicatesAreNotDownloaded() throws {
        let harness = Harness()
        let downloads = harness.make()
        let article = Episode(
            id: 9, title: "Article", description: nil, audioURL: nil, publishedAt: nil, link: nil, hasText: true)
        guard case .nothingToDo = downloads.request([article]) else {
            Issue.record("articles have no audio to download")
            return
        }
        _ = downloads.request([podcast(1)])
        guard case .nothingToDo = downloads.request([podcast(1)]) else {
            Issue.record("already on its way")
            return
        }
        #expect(harness.transport.started.count == 1)
    }

    @Test func askingForAnAutomaticDownloadMakesItManual() async throws {
        let harness = Harness()
        harness.latest = [podcast(1)]
        let downloads = harness.make()
        await downloads.refreshAutomatic(force: true)
        #expect(downloads.record(for: 1)?.origin == .automatic)
        #expect(harness.transport.started.last?.lowPriority == true)
        #expect(harness.transport.started.last?.allowsCellular == false)
        _ = downloads.request([podcast(1)])
        #expect(downloads.record(for: 1)?.origin == .manual)
        // It no longer follows Latest.
        harness.latest = []
        await downloads.refreshAutomatic(force: true)
        #expect(downloads.record(for: 1) != nil)
    }

    @Test func finishedDownloadsGoADayLater() throws {
        let harness = Harness()
        let downloads = harness.make()
        _ = downloads.request([podcast(1)])
        try harness.transport.finish(1)
        let file = try #require(downloads.localFile(for: podcast(1)))
        downloads.markPlayed(1)
        downloads.removeExpired()
        #expect(downloads.record(for: 1) != nil)
        harness.now = harness.now.addingTimeInterval(DownloadPolicy.playedRetention)
        downloads.removeExpired()
        #expect(downloads.record(for: 1) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func markingUnplayedKeepsIt() {
        let harness = Harness()
        let downloads = harness.make()
        _ = downloads.request([podcast(1)])
        downloads.markPlayed(1)
        downloads.markUnplayed(1)
        harness.now = harness.now.addingTimeInterval(2 * DownloadPolicy.playedRetention)
        downloads.removeExpired()
        #expect(downloads.record(for: 1) != nil)
    }

    @Test func loweringTheLimitRemovesAutomaticButNotManual() async throws {
        let harness = Harness()
        harness.latest = [podcast(1, show: "a"), podcast(2, show: "b")]
        let downloads = harness.make()
        await downloads.refreshAutomatic(force: true)
        _ = downloads.request([podcast(3)])
        #expect(downloads.records.count == 3)
        harness.defaults.set(Int(hour), forKey: DownloadSettings.limitKey)
        downloads.enforceLimit()
        #expect(Set(downloads.records.keys) == [3])
        #expect(harness.transport.cancelled.sorted() == [1, 2])
    }

    @Test func signingOutDiscardsLateArrivals() throws {
        let harness = Harness()
        let downloads = harness.make()
        _ = downloads.request([podcast(1)])
        downloads.clear()
        #expect(harness.transport.cancelledAll)
        #expect(downloads.records.isEmpty)
        // The transfer finishes anyway, for the previous account.
        try harness.transport.finish(1)
        #expect(downloads.records.isEmpty)
        #expect(harness.make().records.isEmpty)
    }

    @Test func aFailureIsReportedAndCanBeRetried() {
        let harness = Harness()
        let downloads = harness.make()
        _ = downloads.request([podcast(1)])
        let epoch = harness.transport.started[0].epoch
        harness.transport.onEvent?(.failed(episodeID: 1, epoch: epoch, message: "Lost"))
        #expect(downloads.record(for: 1)?.status == .failed("Lost"))
        #expect(downloads.usedBytes == 0)
        #expect(downloads.request([podcast(1)]) == .started([podcast(1)]))
    }

    @Test func interruptedDownloadsRestartOnTheNextRefresh() async {
        let harness = Harness()
        let first = harness.make()
        _ = first.request([podcast(1)])
        let relaunched = harness.make()
        harness.transport.started = []
        harness.defaults.set(false, forKey: DownloadSettings.automaticKey)
        await relaunched.refreshAutomatic(force: true)
        #expect(harness.transport.started.map(\.episodeID) == [1])
    }
}

@Suite("Download voice commands")
struct DownloadCommandTests {
    @Test(arguments: [
        "download this", "Download this episode.", "can you download this please", "download it",
        "save this for offline", "Download this one for offline",
    ])
    func recognisesDownload(_ transcript: String) {
        #expect(DownloadCommand.match(transcript) == .download)
    }

    @Test(arguments: ["remove this download", "delete the download", "remove this from my downloads"])
    func recognisesRemove(_ transcript: String) {
        #expect(DownloadCommand.match(transcript) == .remove)
    }

    @Test(arguments: [
        "download the new episode of In Our Time", "download the next three episodes", "play this", "downloads",
    ])
    func leavesEverythingElseForTheModel(_ transcript: String) {
        #expect(DownloadCommand.match(transcript) == nil)
    }

    @Test func understandsAnswers() {
        #expect(DownloadCommand.reply("Yes please") == .yes)
        #expect(DownloadCommand.reply("download it anyway") == .yes)
        #expect(DownloadCommand.reply("wait for Wi-Fi") == .waitForWiFi)
        #expect(DownloadCommand.reply("No thank you.") == .no)
        #expect(DownloadCommand.reply("play the news") == nil)
    }
}

@MainActor
final class FakeDownloads: EpisodeDownloading {
    var decision: DownloadDecision = .nothingToDo("")
    var confirmed: [(DownloadConfirmation, Bool)] = []
    var removed: [Int] = []
    var records: [Int: DownloadRecord] = [:]

    func record(for episodeID: Int) -> DownloadRecord? { records[episodeID] }
    func request(_ episodes: [Episode]) -> DownloadDecision { decision }
    func confirm(_ confirmation: DownloadConfirmation, waitForWiFi: Bool) { confirmed.append((confirmation, waitForWiFi)) }
    func remove(episodeID: Int) { removed.append(episodeID) }
}

@MainActor
@Suite("Downloading by voice")
struct DownloadVoiceTests {
    private func make(_ transcripts: [String], playing: Episode? = podcast(7))
        -> (VoiceController, Recorder, FakeDownloads)
    {
        let recorder = Recorder()
        let speech = FakeSpeech()
        speech.transcripts = transcripts
        speech.transcript = ""
        let player = FakePlayer(recorder)
        player.currentEpisode = playing
        let downloads = FakeDownloads()
        let api = FakeAPI()
        let controller = VoiceController(
            api: api, speech: speech, speaker: FakeSpeaker(recorder), player: player,
            feedback: FakeFeedback(recorder),
            sleepTimer: SleepTimer(
                player: PlaybackCoordinator(
                    audio: AudioPlayer(), article: ArticlePlayer(api: api, synthesizer: SilentSynthesizer())),
                feedback: FakeFeedback(recorder)),
            downloads: downloads,
            conversationPreferences: { VoiceConversationPreferences(keepListening: false) },
            progressDelay: { _ in }, listeningDeadlineSleep: { _ in try await Task.sleep(for: .seconds(60)) })
        return (controller, recorder, downloads)
    }

    private func confirmation(mobile: Bool) -> DownloadConfirmation {
        DownloadConfirmation(
            episodes: [podcast(7)], estimatedBytes: hour, limitBytes: 2_000_000_000,
            overLimitBytes: mobile ? 0 : hour, usesMobileData: mobile)
    }

    @Test func downloadsWhatIsPlaying() async {
        let (controller, recorder, downloads) = make(["download this"])
        downloads.decision = .started([podcast(7)])
        await controller.beginCommand()
        #expect(recorder.spoken == ["Downloading Episode 7."])
    }

    @Test func overTheLimitAsksAloudAndAcceptsAYes() async {
        let (controller, recorder, downloads) = make(["download this", "yes"])
        downloads.decision = .needsConfirmation(confirmation(mobile: false))
        await controller.beginCommand()
        #expect(recorder.spoken.first?.contains("more than your 2 gigabyte download limit") == true)
        #expect(recorder.spoken.last == "Downloading Episode 7.")
        #expect(downloads.confirmed.count == 1)
        #expect(downloads.confirmed.first?.1 == false)
    }

    @Test func mobileDataCanWaitForWiFi() async {
        let (controller, recorder, downloads) = make(["download it", "wait for wifi"])
        downloads.decision = .needsConfirmation(confirmation(mobile: true))
        await controller.beginCommand()
        #expect(downloads.confirmed.first?.1 == true)
        #expect(recorder.spoken.last == "I will download Episode 7 when you are on Wi-Fi.")
    }

    @Test func aNoDownloadsNothing() async {
        let (controller, recorder, downloads) = make(["download this", "no"])
        downloads.decision = .needsConfirmation(confirmation(mobile: false))
        await controller.beginCommand()
        #expect(downloads.confirmed.isEmpty)
        #expect(recorder.spoken.last == "OK, I will not download it.")
    }

    @Test func nothingPlayingIsExplained() async {
        let (controller, recorder, _) = make(["download this"], playing: nil)
        await controller.beginCommand()
        #expect(recorder.spoken.first?.hasPrefix("Nothing is playing") == true)
    }

    @Test func removesTheDownload() async {
        let (controller, recorder, downloads) = make(["remove this download"])
        downloads.records[7] = record(7, origin: .manual)
        await controller.beginCommand()
        #expect(downloads.removed == [7])
        #expect(recorder.spoken == ["Removed the download of Episode 7."])
    }
}
