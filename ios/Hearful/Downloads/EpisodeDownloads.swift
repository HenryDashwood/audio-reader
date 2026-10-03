import Combine
import Foundation
import Network
import OSLog
import SwiftUI

private nonisolated let log = Logger(subsystem: "com.henrydashwood.hearful", category: "downloads")

/// What happens when she asks for one or more episodes to be downloaded.
enum DownloadDecision: Equatable {
    case started([Episode])
    /// Nothing new to fetch; the message says why.
    case nothingToDo(String)
    /// Will not fit on the phone at all.
    case refused(String)
    case needsConfirmation(DownloadConfirmation)
}

/// A download she asked for that needs a yes first, because it goes over her
/// storage limit or would use mobile data.
struct DownloadConfirmation: Equatable, Identifiable {
    let id = UUID()
    let episodes: [Episode]
    let estimatedBytes: Int64
    let limitBytes: Int64?
    /// How far over the limit, after removing everything that may be removed.
    let overLimitBytes: Int64
    let usesMobileData: Bool

    private var subject: String {
        episodes.count == 1 ? "This episode" : "These \(episodes.count) episodes"
    }

    var title: String {
        if overLimitBytes > 0 { return "Over your download limit" }
        return "Download using mobile data?"
    }

    /// For the on-screen dialog.
    var message: String {
        var lines: [String] = []
        if overLimitBytes > 0, let limitBytes {
            lines.append("\(subject) will use about \(formatBytes(overLimitBytes)) more than your \(formatBytes(limitBytes)) download limit.")
        } else {
            lines.append("\(subject) will use about \(formatBytes(estimatedBytes)).")
        }
        if usesMobileData { lines.append("You are not on Wi-Fi.") }
        return lines.joined(separator: " ")
    }

    /// For a voice request: a question she can answer with yes, no, or wait.
    var spokenQuestion: String {
        var lines: [String] = []
        if overLimitBytes > 0, let limitBytes {
            lines.append("That will use about \(spokenBytes(overLimitBytes)) more than your \(spokenBytes(limitBytes, adjective: true)) download limit.")
        }
        if usesMobileData {
            lines.append("You are not on Wi-Fi. Shall I download it now using mobile data, or wait for Wi-Fi?")
        } else {
            lines.append("Shall I download it anyway?")
        }
        return lines.joined(separator: " ")
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
protocol EpisodeDownloading: AnyObject {
    func record(for episodeID: Int) -> DownloadRecord?
    func request(_ episodes: [Episode]) -> DownloadDecision
    func confirm(_ confirmation: DownloadConfirmation, waitForWiFi: Bool)
    func remove(episodeID: Int)
}

/// Episode audio kept on the phone so it plays with no connection.
///
/// Manual downloads stay until she has finished them; automatic ones follow
/// Latest within her storage limit. Everything is thrown away on sign-out.
@MainActor
final class EpisodeDownloads: ObservableObject, EpisodeDownloading {
    static let shared = EpisodeDownloads()

    @Published private(set) var records: [Int: DownloadRecord] = [:]

    private let store: DownloadStore
    private let defaults: UserDefaults
    private let makeTransport: @MainActor (URL) -> DownloadTransport
    private var transportInstance: DownloadTransport?
    private let latest: @MainActor () async throws -> [Episode]
    private let isSignedIn: @MainActor () -> Bool
    private let protecting: @MainActor () -> Int?
    private let mobileDataOverride: (@MainActor () -> Bool)?
    private let freeSpace: @MainActor () -> Int64?
    private let now: @MainActor () -> Date
    private var epoch: UUID
    private var lastAutomaticRefresh = Date.distantPast
    private var refreshing = false
    private var reconciled = false
    private var subscriptions: Set<AnyCancellable> = []
    private let pathMonitor = NWPathMonitor()
    private var pathIsExpensive = false

    init(
        store: DownloadStore = DownloadStore(),
        defaults: UserDefaults = .standard,
        makeTransport: @escaping @MainActor (URL) -> DownloadTransport = { BackgroundDownloadTransport(incoming: $0) },
        latest: @escaping @MainActor () async throws -> [Episode] = { try await HearfulAPI().recentEpisodes(limit: 100) },
        isSignedIn: @escaping @MainActor () -> Bool = { ShortcutScope.current != nil },
        protecting: (@MainActor () -> Int?)? = nil,
        isOnMobileData: (@MainActor () -> Bool)? = nil,
        freeSpace: (@MainActor () -> Int64?)? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        observesSystem: Bool = true
    ) {
        self.store = store
        self.defaults = defaults
        self.makeTransport = makeTransport
        self.latest = latest
        self.isSignedIn = isSignedIn
        self.protecting = protecting ?? { AudioPlayer.shared.currentEpisode?.id }
        self.freeSpace = freeSpace ?? { store.freeSpace() }
        self.now = now
        mobileDataOverride = isOnMobileData
        let manifest = store.load()
        epoch = manifest.epoch
        var loaded: [Int: DownloadRecord] = [:]
        for var record in manifest.records {
            // A downloaded file that has gone is a download that has gone.
            if record.status == .downloaded, record.filename.map(store.exists) != true { continue }
            if case .downloading = record.status { record.status = .queued(waitingForWiFi: false) }
            loaded[record.id] = record
        }
        records = loaded
        store.removeOrphans(keeping: Set(loaded.values.compactMap(\.filename)))
        if observesSystem { observe() }
    }

    var settings: DownloadSettings { DownloadSettings.load(defaults) }

    private func isOnMobileData() -> Bool { mobileDataOverride?() ?? pathIsExpensive }

    /// Bytes on the phone or on their way, for the Settings screen.
    var usedBytes: Int64 { DownloadPolicy.used(Array(records.values)) }

    var sortedRecords: [DownloadRecord] {
        records.values.sorted {
            if $0.status.isActive != $1.status.isActive { return $0.status.isActive }
            return $0.requestedAt > $1.requestedAt
        }
    }

    func record(for episodeID: Int) -> DownloadRecord? { records[episodeID] }

    /// The audio on the phone, when it has all arrived.
    func localFile(for episode: Episode) -> URL? {
        guard let record = records[episode.id], record.status == .downloaded, let filename = record.filename,
            store.exists(filename)
        else { return nil }
        return store.file(filename)
    }

    // MARK: - Asking

    /// Starts what can be started without asking, or says what needs a yes.
    func request(_ episodes: [Episode]) -> DownloadDecision {
        let audio = episodes.filter { $0.audioURL != nil }
        guard !audio.isEmpty else { return .nothingToDo("Only podcast episodes can be downloaded. Articles are kept on your iPhone once loaded.") }
        var wanted: [Episode] = []
        for episode in audio {
            guard let existing = records[episode.id] else {
                wanted.append(episode)
                continue
            }
            if case .failed = existing.status {
                wanted.append(episode)
            } else {
                // Already here or on its way: asking for it makes it hers, so
                // it is no longer removed to make room.
                promote(episode.id)
            }
        }
        guard !wanted.isEmpty else {
            let underway = audio.contains { records[$0.id]?.status.isActive == true }
            let state = underway ? "already downloading" : "already downloaded"
            return .nothingToDo(audio.count == 1 ? "\(audio[0].title) is \(state)." : "Those episodes are \(state).")
        }
        let bytes = wanted.reduce(0) { $0 + DownloadPolicy.estimate($1) }
        if let space = freeSpace(), space - bytes < DownloadPolicy.freeSpaceMargin {
            return .refused("There is not enough space on this iPhone. \(wanted.count == 1 ? "This episode needs" : "These episodes need") about \(formatBytes(bytes)). Remove some downloads or other things from the iPhone, then try again.")
        }
        let current = Array(records.values)
        let overage = DownloadPolicy.overage(adding: bytes, records: current, limit: settings.limit, protecting: protecting())
        let mobile = settings.wifiOnly && isOnMobileData()
        if overage > 0 || mobile {
            return .needsConfirmation(DownloadConfirmation(
                episodes: wanted, estimatedBytes: bytes, limitBytes: settings.limit, overLimitBytes: overage,
                usesMobileData: mobile))
        }
        enqueue(wanted, origin: .manual, allowsCellular: true)
        return .started(wanted)
    }

    func confirm(_ confirmation: DownloadConfirmation, waitForWiFi: Bool) {
        enqueue(confirmation.episodes, origin: .manual, allowsCellular: !waitForWiFi)
    }

    func remove(episodeID: Int) {
        guard let record = records[episodeID] else { return }
        if record.status.isActive { transport.cancel(episodeID: episodeID) }
        store.remove(record.filename)
        records[episodeID] = nil
        persist()
    }

    func removeAll() {
        for record in records.values where record.status.isActive { transport.cancel(episodeID: record.id) }
        for record in records.values { store.remove(record.filename) }
        records = [:]
        persist()
    }

    /// Sign-out or a server change: nothing here belongs to whoever is next.
    func clear() {
        transportInstance?.cancelAll()
        epoch = UUID()
        records = [:]
        store.clear()
        lastAutomaticRefresh = .distantPast
        persist()
    }

    // MARK: - Automatic downloads

    /// Brings automatic downloads into line with Latest and the settings.
    /// Throttled; `force` is for a settings change.
    func refreshAutomatic(force: Bool = false) async {
        guard isSignedIn(), !refreshing else { return }
        guard force || now().timeIntervalSince(lastAutomaticRefresh) >= 15 * 60 else { return }
        refreshing = true
        defer { refreshing = false }
        await reconcileWithSystem()
        removeExpired()
        let settings = settings
        let episodes: [Episode]
        if settings.automatic {
            do { episodes = try await latest() } catch {
                // Offline: keep what is here and try again later.
                return
            }
        } else {
            episodes = []
        }
        guard isSignedIn() else { return }
        lastAutomaticRefresh = now()
        let plan = DownloadPolicy.automaticPlan(
            latest: episodes, records: Array(records.values), settings: settings, protecting: protecting(),
            freeSpace: freeSpace())
        for id in plan.remove { removeQuietly(id) }
        enqueue(plan.start, origin: .automatic, allowsCellular: !settings.wifiOnly)
        enforceLimit()
    }

    /// After lowering the limit: remove what may be removed until it fits.
    func enforceLimit() {
        let evict = DownloadPolicy.evictions(
            adding: 0, records: Array(records.values), limit: settings.limit, protecting: protecting())
        for id in evict { removeQuietly(id) }
        if !evict.isEmpty { persist() }
    }

    func settingsChanged() {
        enforceLimit()
        Task { await refreshAutomatic(force: true) }
    }

    /// Called when the system relaunches the app to deliver finished
    /// background transfers.
    func handleBackgroundEvents() async {
        _ = transport
        await transport.finishBackgroundEvents()
    }

    // MARK: - Played

    func markPlayed(_ episodeID: Int) {
        guard records[episodeID] != nil, records[episodeID]?.playedAt == nil else { return }
        records[episodeID]?.playedAt = now()
        persist()
    }

    func markUnplayed(_ episodeID: Int) {
        guard records[episodeID]?.playedAt != nil else { return }
        records[episodeID]?.playedAt = nil
        persist()
    }

    func removeExpired() {
        let expired = DownloadPolicy.expired(Array(records.values), now: now(), protecting: protecting())
        for id in expired { removeQuietly(id) }
        if !expired.isEmpty { persist() }
    }

    // MARK: - Transfers

    private var transport: DownloadTransport {
        if let transportInstance { return transportInstance }
        let created = makeTransport(store.incoming)
        created.onEvent = { [weak self] event in self?.handle(event) }
        transportInstance = created
        return created
    }

    private func enqueue(_ episodes: [Episode], origin: DownloadOrigin, allowsCellular: Bool) {
        guard !episodes.isEmpty else { return }
        for episode in episodes {
            guard let url = episode.audioURL else { continue }
            let bytes = DownloadPolicy.estimate(episode)
            if origin == .manual {
                let evict = DownloadPolicy.evictions(
                    adding: bytes, records: Array(records.values).filter { $0.id != episode.id },
                    limit: settings.limit, protecting: protecting())
                for id in evict { removeQuietly(id) }
            }
            records[episode.id] = DownloadRecord(
                episode: episode, origin: origin,
                status: .queued(waitingForWiFi: !allowsCellular && isOnMobileData()),
                bytes: bytes, requestedAt: now())
            transport.start(DownloadTaskRequest(
                episodeID: episode.id, url: url, epoch: epoch, allowsCellular: allowsCellular,
                expectedBytes: bytes, lowPriority: origin == .automatic))
        }
        persist()
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let id, let eventEpoch, let fraction):
            guard eventEpoch == epoch, let record = records[id], record.status.isActive else { return }
            // Published in whole steps of a few percent: every list row
            // observes this, and redrawing them for each packet is waste.
            if case .downloading(let previous) = record.status, abs(previous - fraction) < 0.05, fraction < 1 { return }
            records[id]?.status = .downloading(progress: fraction)
        case .finished(let id, let eventEpoch, let file):
            guard eventEpoch == epoch, let record = records[id], record.status.isActive else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            do {
                let (filename, bytes) = try store.adopt(file, episodeID: id)
                records[id]?.filename = filename
                records[id]?.bytes = bytes
                records[id]?.status = .downloaded
                persist()
                if record.origin == .manual {
                    AccessibilityNotification.Announcement("Downloaded: \(record.episode.title)").post()
                }
            } catch {
                try? FileManager.default.removeItem(at: file)
                fail(id, message: "The episode could not be saved on this iPhone.")
            }
        case .failed(let id, let eventEpoch, let message):
            guard eventEpoch == epoch else { return }
            fail(id, message: message)
        }
    }

    private func fail(_ id: Int, message: String) {
        guard let record = records[id], record.status.isActive else { return }
        records[id]?.status = .failed(message)
        persist()
        if record.origin == .manual {
            AccessibilityNotification.Announcement("Download failed: \(record.episode.title)").post()
        }
    }

    private func promote(_ id: Int) {
        guard records[id]?.origin == .automatic else { return }
        records[id]?.origin = .manual
        persist()
    }

    private func removeQuietly(_ id: Int) {
        guard let record = records[id] else { return }
        if record.status.isActive { transport.cancel(episodeID: id) }
        store.remove(record.filename)
        records[id] = nil
    }

    /// Restarts anything the manifest says is under way that the system no
    /// longer knows about — after the app was force-quit, for instance.
    private func reconcileWithSystem() async {
        guard !reconciled else { return }
        reconciled = true
        let active = Set(await transport.activeTasks().filter { $0.epoch == epoch }.map(\.episodeID))
        for record in records.values where record.status.isActive && !active.contains(record.id) {
            guard let url = record.episode.audioURL else { continue }
            transport.start(DownloadTaskRequest(
                episodeID: record.id, url: url, epoch: epoch,
                allowsCellular: record.origin == .manual ? !isWaitingForWiFi(record) : !settings.wifiOnly,
                expectedBytes: record.bytes, lowPriority: record.origin == .automatic))
        }
    }

    private func isWaitingForWiFi(_ record: DownloadRecord) -> Bool {
        if case .queued(true) = record.status { true } else { false }
    }

    private func persist() {
        do {
            try store.save(DownloadManifest(epoch: epoch, records: Array(records.values)))
        } catch {
            log.error("could not save download manifest: \(error.localizedDescription)")
        }
    }

    private func observe() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.pathIsExpensive = expensive }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.henrydashwood.hearful.downloads.path"))
        let center = NotificationCenter.default
        center.publisher(for: .hearfulPositionReported)
            .sink { [weak self] note in
                guard let report = note.object as? PositionReport, report.completed else { return }
                MainActor.assumeIsolated { self?.markPlayed(report.episodeID) }
            }
            .store(in: &subscriptions)
        center.publisher(for: .hearfulEpisodeFiled)
            .sink { [weak self] note in
                guard let change = note.object as? EpisodeFiling.Change else { return }
                MainActor.assumeIsolated {
                    switch change.filing {
                    case .played: self?.markPlayed(change.episodeID)
                    case .restored: self?.markUnplayed(change.episodeID)
                    case .dismissed: break
                    }
                }
            }
            .store(in: &subscriptions)
        // Foregrounding and a restored connection; the throttle keeps this to
        // a request every quarter of an hour at most.
        center.publisher(for: .hearfulRetryOffline)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refreshAutomatic() }
                }
            }
            .store(in: &subscriptions)
    }
}
