import Foundation
import OSLog

private nonisolated let log = Logger(subsystem: "com.henrydashwood.hearful", category: "downloads")

nonisolated enum DownloadEvent: Sendable {
    case progress(episodeID: Int, epoch: UUID, fraction: Double)
    /// The file has already been moved out of URLSession's temporary location.
    case finished(episodeID: Int, epoch: UUID, file: URL)
    case failed(episodeID: Int, epoch: UUID, message: String)
}

nonisolated struct DownloadTaskRequest: Sendable {
    let episodeID: Int
    let url: URL
    let epoch: UUID
    let allowsCellular: Bool
    let expectedBytes: Int64
    let lowPriority: Bool
}

@MainActor
protocol DownloadTransport: AnyObject {
    var onEvent: (@MainActor (DownloadEvent) -> Void)? { get set }
    func start(_ request: DownloadTaskRequest)
    func cancel(episodeID: Int)
    func cancelAll()
    /// Episode IDs and epochs with a transfer still in the system's hands.
    func activeTasks() async -> [(episodeID: Int, epoch: UUID)]
    /// Returns once the system has delivered every event it woke the app for.
    func finishBackgroundEvents() async
}

/// Downloads that carry on when Magpie is in the background or closed, so
/// queueing a dozen episodes before a flight does not require keeping the
/// screen on.
@MainActor
final class BackgroundDownloadTransport: DownloadTransport {
    static let identifier = "com.henrydashwood.hearful.downloads"

    var onEvent: (@MainActor (DownloadEvent) -> Void)? {
        get { relay.onEvent }
        set { relay.onEvent = newValue }
    }
    private let relay = DownloadEventRelay()
    private let session: URLSession

    init(incoming: URL) {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        // Podcast hosts are slow and often redirect several times; a
        // background transfer may wait for a connection for a day.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(
            configuration: configuration,
            delegate: DownloadSessionDelegate(incoming: incoming, relay: relay),
            delegateQueue: nil)
    }

    func start(_ request: DownloadTaskRequest) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.allowsCellularAccess = request.allowsCellular
        urlRequest.allowsExpensiveNetworkAccess = request.allowsCellular
        urlRequest.allowsConstrainedNetworkAccess = request.allowsCellular
        let task = session.downloadTask(with: urlRequest)
        task.taskDescription = "\(request.epoch.uuidString) \(request.episodeID)"
        task.countOfBytesClientExpectsToReceive = request.expectedBytes
        task.priority = request.lowPriority ? URLSessionTask.lowPriority : URLSessionTask.highPriority
        task.resume()
    }

    func cancel(episodeID: Int) {
        session.getAllTasks { tasks in
            for task in tasks where Self.parse(task.taskDescription)?.episodeID == episodeID { task.cancel() }
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    func activeTasks() async -> [(episodeID: Int, epoch: UUID)] {
        await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
            .compactMap { Self.parse($0.taskDescription) }
    }

    func finishBackgroundEvents() async {
        await relay.finishBackgroundEvents()
    }

    nonisolated static func parse(_ description: String?) -> (episodeID: Int, epoch: UUID)? {
        let parts = description?.split(separator: " ") ?? []
        guard parts.count == 2, let epoch = UUID(uuidString: String(parts[0])), let id = Int(parts[1]) else {
            return nil
        }
        return (id, epoch)
    }
}

/// Carries delegate callbacks to the main actor. The session is created
/// before the transport has finished initialising, so the delegate cannot hold
/// the transport itself.
@MainActor
private final class DownloadEventRelay {
    var onEvent: (@MainActor (DownloadEvent) -> Void)?
    private var eventsDone = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finishBackgroundEvents() async {
        if eventsDone {
            eventsDone = false
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func backgroundEventsFinished() {
        guard !waiters.isEmpty else {
            eventsDone = true
            return
        }
        let current = waiters
        waiters = []
        current.forEach { $0.resume() }
    }
}

/// Holds no mutable state: every callback is translated into an event and
/// handed to the main actor. Sendable because its properties are immutable
/// and themselves Sendable.
private nonisolated final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let incoming: URL
    private let relay: DownloadEventRelay

    init(incoming: URL, relay: DownloadEventRelay) {
        self.incoming = incoming
        self.relay = relay
    }

    private func send(_ event: DownloadEvent) {
        Task { @MainActor [relay] in relay.onEvent?(event) }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let (id, epoch) = BackgroundDownloadTransport.parse(downloadTask.taskDescription) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        guard let response, (200..<300).contains(response.statusCode) else {
            send(.failed(episodeID: id, epoch: epoch,
                         message: "The podcast’s server would not send this episode."))
            return
        }
        if response.mimeType?.hasPrefix("text/") == true {
            send(.failed(episodeID: id, epoch: epoch, message: "The podcast’s server sent a web page instead of audio."))
            return
        }
        // The temporary file is deleted as soon as this method returns, so it
        // has to be moved here rather than on the main actor.
        let ext = Self.fileExtension(response: response, url: downloadTask.originalRequest?.url)
        let destination = incoming.appending(path: "\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            send(.finished(episodeID: id, epoch: epoch, file: destination))
        } catch {
            log.error("could not keep download \(id): \(error.localizedDescription)")
            send(.failed(episodeID: id, epoch: epoch, message: "The episode could not be saved on this iPhone."))
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let (id, epoch) = BackgroundDownloadTransport.parse(downloadTask.taskDescription) else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : downloadTask.countOfBytesClientExpectsToReceive
        let fraction = expected > 0 ? min(Double(totalBytesWritten) / Double(expected), 1) : 0
        send(.progress(episodeID: id, epoch: epoch, fraction: fraction))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (id, epoch) = BackgroundDownloadTransport.parse(task.taskDescription) else { return }
        // Cancellation is always ours: a removal or sign-out already updated
        // the manifest.
        if (error as? URLError)?.code == .cancelled { return }
        log.notice("download \(id) failed: \(error.localizedDescription)")
        send(.failed(episodeID: id, epoch: epoch, message: Self.explain(error)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [relay] in relay.backgroundEventsFinished() }
    }

    private static func explain(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut:
            "The connection was lost before the episode finished downloading."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            "The podcast’s server could not be reached."
        default: "The episode could not be downloaded."
        }
    }

    private static func fileExtension(response: HTTPURLResponse, url: URL?) -> String {
        switch response.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/aac", "audio/x-aac": return "aac"
        case "video/mp4": return "mp4"
        default: break
        }
        let candidates = [response.url?.pathExtension, url?.pathExtension].compactMap { $0?.lowercased() }
        return candidates.first { ["mp3", "m4a", "aac", "mp4", "m4b", "wav"].contains($0) } ?? "mp3"
    }
}
