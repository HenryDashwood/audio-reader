import Foundation
import OSLog

private nonisolated let log = Logger(subsystem: "com.henrydashwood.hearful", category: "downloads")

/// How much episode audio the phone may keep, and what may arrive unasked.
///
/// Stored in UserDefaults so the Settings screen can bind to the same keys
/// with @AppStorage; the defaults here and there must agree.
nonisolated struct DownloadSettings: Equatable, Sendable {
    static let limitKey = "Hearful.downloads.limitBytes"
    static let automaticKey = "Hearful.downloads.automatic"
    static let perShowKey = "Hearful.downloads.perShow"
    static let wifiOnlyKey = "Hearful.downloads.wifiOnly"

    static let gigabyte = 1_000_000_000
    /// Zero means no limit.
    static let limitOptions = [1, 2, 5, 10].map { $0 * gigabyte } + [0]
    static let perShowOptions = [1, 2, 3]

    static let defaultLimit = 2 * gigabyte
    static let defaultAutomatic = true
    static let defaultPerShow = 1
    static let defaultWiFiOnly = true

    var limitBytes = Self.defaultLimit
    var automatic = Self.defaultAutomatic
    var perShow = Self.defaultPerShow
    var wifiOnly = Self.defaultWiFiOnly

    var limit: Int64? { limitBytes > 0 ? Int64(limitBytes) : nil }

    static func load(_ defaults: UserDefaults) -> DownloadSettings {
        var settings = DownloadSettings()
        if let value = defaults.object(forKey: limitKey) as? Int, value >= 0 { settings.limitBytes = value }
        if let value = defaults.object(forKey: automaticKey) as? Bool { settings.automatic = value }
        if let value = defaults.object(forKey: perShowKey) as? Int, perShowOptions.contains(value) {
            settings.perShow = value
        }
        if let value = defaults.object(forKey: wifiOnlyKey) as? Bool { settings.wifiOnly = value }
        return settings
    }

    static func limitLabel(_ bytes: Int) -> String {
        bytes > 0 ? formatBytes(Int64(bytes)) : "No limit"
    }
}

nonisolated enum DownloadOrigin: String, Codable, Sendable {
    /// She asked for it. Never removed to make room while it is unheard.
    case manual
    /// Fetched because it is new in a show she follows.
    case automatic
}

nonisolated enum DownloadStatus: Codable, Equatable, Sendable {
    case queued(waitingForWiFi: Bool)
    case downloading(progress: Double)
    case downloaded
    case failed(String)

    var isActive: Bool {
        switch self {
        case .queued, .downloading: true
        case .downloaded, .failed: false
        }
    }
}

nonisolated struct DownloadRecord: Codable, Equatable, Identifiable, Sendable {
    var id: Int { episode.id }
    /// A copy of the episode as it was when requested, so the download can be
    /// listed and played with no connection and no other cache.
    var episode: Episode
    var origin: DownloadOrigin
    var status: DownloadStatus
    /// Relative to the downloads directory, once the audio has arrived.
    var filename: String?
    /// The measured size once downloaded; an estimate until then.
    var bytes: Int64
    var requestedAt: Date
    /// When she finished it. Played downloads are the first to go.
    var playedAt: Date?

    /// The label used in rows and the Downloads list.
    var statusLabel: String {
        switch status {
        case .queued(let waitingForWiFi): waitingForWiFi ? "Waiting for Wi-Fi" : "Waiting to download"
        case .downloading(let progress):
            progress > 0 ? "Downloading \(Int((progress * 100).rounded()))%" : "Downloading"
        case .downloaded: "Downloaded"
        case .failed: "Download failed"
        }
    }
}

nonisolated struct DownloadManifest: Codable, Equatable, Sendable {
    var schema = 1
    /// Changes whenever every download is thrown away, so a transfer started
    /// before sign-out cannot land in the next person's library.
    var epoch = UUID()
    var records: [DownloadRecord] = []
}

/// The rules about what to keep, separate from files and network so the tests
/// can exercise them directly.
nonisolated enum DownloadPolicy {
    /// 128 kbit/s, the common podcast bitrate. Feeds rarely state a size the
    /// app could trust, so the duration is the better predictor.
    static let bytesPerSecond: Int64 = 16_000
    static let fallbackBytes: Int64 = 50_000_000
    /// Long enough to go back to the end of something she just finished.
    static let playedRetention: TimeInterval = 24 * 60 * 60
    /// Left free on the phone however generous the limit, so a download never
    /// takes the space needed for photos or a system update.
    static let freeSpaceMargin: Int64 = 500_000_000

    static func estimate(_ episode: Episode) -> Int64 {
        guard let seconds = episode.durationSeconds, seconds > 0 else { return fallbackBytes }
        return Int64(seconds) * bytesPerSecond
    }

    /// Space already taken or promised. Failed downloads hold nothing.
    static func used(_ records: [DownloadRecord]) -> Int64 {
        records.filter { if case .failed = $0.status { false } else { true } }.reduce(0) { $0 + $1.bytes }
    }

    /// What may be deleted to make room, in the order to delete it: things
    /// she has finished, oldest first, then automatic downloads, oldest first.
    /// Unheard manual downloads and whatever is loaded in the player are kept.
    static func evictable(_ records: [DownloadRecord], protecting: Int?) -> [DownloadRecord] {
        let candidates = records.filter { $0.id != protecting && !isFailed($0) }
        let played = candidates.filter { $0.playedAt != nil }.sorted { $0.playedAt! < $1.playedAt! }
        let automatic = candidates.filter { $0.playedAt == nil && $0.origin == .automatic }
            .sorted { $0.requestedAt < $1.requestedAt }
        return played + automatic
    }

    /// The downloads to delete so `adding` more bytes fits under the limit,
    /// as far as that is possible.
    static func evictions(
        adding: Int64, records: [DownloadRecord], limit: Int64?, protecting: Int?,
        onlyPlayed: Bool = false
    ) -> [Int] {
        guard let limit else { return [] }
        var excess = used(records) + adding - limit
        var removed: [Int] = []
        for record in evictable(records, protecting: protecting) where excess > 0 {
            if onlyPlayed && record.playedAt == nil { break }
            removed.append(record.id)
            excess -= record.bytes
        }
        return removed
    }

    /// How far over the limit the downloads would be after removing
    /// everything that may be removed. Zero when it fits.
    static func overage(adding: Int64, records: [DownloadRecord], limit: Int64?, protecting: Int?) -> Int64 {
        guard let limit else { return 0 }
        let freed = evictable(records, protecting: protecting).reduce(0) { $0 + $1.bytes }
        return max(0, used(records) - freed + adding - limit)
    }

    static func expired(_ records: [DownloadRecord], now: Date, protecting: Int?) -> [Int] {
        records.filter {
            $0.id != protecting && $0.playedAt.map { now.timeIntervalSince($0) >= playedRetention } == true
        }.map(\.id)
    }

    struct AutomaticPlan: Equatable {
        var start: [Episode] = []
        var remove: [Int] = []
    }

    /// The newest unheard episodes of each followed show, from Latest. Latest
    /// already leaves out what she has played or put aside, so an automatic
    /// download that drops out of it is no longer wanted.
    static func automaticPlan(
        latest: [Episode], records: [DownloadRecord], settings: DownloadSettings, protecting: Int?,
        freeSpace: Int64?
    ) -> AutomaticPlan {
        var perShow: [String: Int] = [:]
        var wanted: [Episode] = []
        if settings.automatic {
            for episode in latest where episode.audioURL != nil && episode.completed != true
                && episode.dismissed != true
            {
                let show = episode.feedURL?.absoluteString ?? episode.feedTitle ?? "episode-\(episode.id)"
                guard perShow[show, default: 0] < settings.perShow else { continue }
                perShow[show, default: 0] += 1
                wanted.append(episode)
            }
        }
        let wantedIDs = Set(wanted.map(\.id))
        var plan = AutomaticPlan()
        plan.remove = records.filter {
            $0.origin == .automatic && $0.playedAt == nil && !wantedIDs.contains($0.id) && $0.id != protecting
        }.map(\.id)
        var remaining = records.filter { !plan.remove.contains($0.id) }
        var space = freeSpace
        // A failed automatic download is tried again; anything else already
        // on the list is left as it is.
        for episode in wanted
        where records.first(where: { $0.id == episode.id }).map({ $0.origin == .automatic && isFailed($0) }) ?? true {
            let bytes = estimate(episode)
            if let available = space, available - bytes < freeSpaceMargin { break }
            // An automatic download makes room only by removing what she has
            // already finished; it never displaces another unheard episode.
            let evict = evictions(
                adding: bytes, records: remaining, limit: settings.limit, protecting: protecting, onlyPlayed: true)
            let after = remaining.filter { !evict.contains($0.id) }
            if let limit = settings.limit, used(after) + bytes > limit { break }
            plan.remove += evict
            remaining = after + [
                DownloadRecord(
                    episode: episode, origin: .automatic, status: .queued(waitingForWiFi: false),
                    bytes: bytes, requestedAt: .now)
            ]
            space = space.map { $0 - bytes }
            plan.start.append(episode)
        }
        return plan
    }

    private static func isFailed(_ record: DownloadRecord) -> Bool {
        if case .failed = record.status { true } else { false }
    }
}

/// The audio files and the manifest describing them, in Application Support
/// and out of iCloud backups: they can always be downloaded again.
nonisolated struct DownloadStore: Sendable {
    let directory: URL
    var incoming: URL { directory.appending(path: "Incoming", directoryHint: .isDirectory) }
    private var manifestURL: URL { directory.appending(path: "manifest.json") }

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load() -> DownloadManifest {
        guard let data = try? Data(contentsOf: manifestURL) else { return DownloadManifest() }
        do {
            let manifest = try Self.decoder.decode(DownloadManifest.self, from: data)
            guard manifest.schema == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return manifest
        } catch {
            // Without the manifest the files cannot be attributed to an
            // account; they are deleted rather than guessed at.
            log.error("discarding unreadable download manifest: \(error.localizedDescription)")
            clear()
            return DownloadManifest()
        }
    }

    func save(_ manifest: DownloadManifest) throws {
        try prepare()
        try Self.encoder.encode(manifest).write(
            to: manifestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    func file(_ filename: String) -> URL { directory.appending(path: filename) }

    func exists(_ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: file(filename).path)
    }

    func remove(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: file(filename))
    }

    /// Moves an arrived file into place under the episode's own name.
    func adopt(_ incomingFile: URL, episodeID: Int) throws -> (filename: String, bytes: Int64) {
        try prepare()
        let ext = incomingFile.pathExtension.isEmpty ? "mp3" : incomingFile.pathExtension
        let filename = "\(episodeID).\(ext)"
        let destination = file(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: incomingFile, to: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        return (filename, Int64(size))
    }

    /// Deletes audio the manifest does not account for, such as a transfer
    /// that landed while the app was being closed.
    func removeOrphans(keeping filenames: Set<String>) {
        let manager = FileManager.default
        for url in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent != "manifest.json" && url.lastPathComponent != "Incoming"
            && !filenames.contains(url.lastPathComponent)
        {
            try? manager.removeItem(at: url)
        }
        for url in (try? manager.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)) ?? [] {
            try? manager.removeItem(at: url)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// What the system would let an app use for something she asked for.
    func freeSpace() -> Int64? {
        let probe = FileManager.default.fileExists(atPath: directory.path) ? directory : URL.applicationSupportDirectory
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

nonisolated func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// "60 megabytes" rather than "60 MB", which a synthesiser reads out as
/// letters. `adjective` gives "a 2 gigabyte limit".
nonisolated func spokenBytes(_ bytes: Int64, adjective: Bool = false) -> String {
    let megabytes = Double(bytes) / 1_000_000
    if megabytes < 1000 {
        let rounded = megabytes < 10 ? max(1, Int(megabytes.rounded())) : Int((megabytes / 10).rounded()) * 10
        return "\(rounded) megabyte\(rounded == 1 || adjective ? "" : "s")"
    }
    let gigabytes = (megabytes / 100).rounded() / 10
    let text = gigabytes == gigabytes.rounded() ? String(Int(gigabytes)) : String(format: "%.1f", gigabytes)
    return "\(text) gigabyte\(gigabytes == 1 || adjective ? "" : "s")"
}
