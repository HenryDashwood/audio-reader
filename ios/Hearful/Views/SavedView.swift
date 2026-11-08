import SwiftUI
import QuickLook

extension Notification.Name {
    nonisolated static let hearfulSavedChanged = Notification.Name("hearfulSavedChanged")
}

@MainActor
final class SavedLibrary: ObservableObject {
    static let shared = SavedLibrary()
    @Published var episodes: [Episode] = []
    @Published var pending: [CaptureInbox.Capture] = []
    @Published var pendingPDFs: [PDFUploadInbox.Pending] = []
    @Published var error: String?
    @Published var loading = false
    @Published private(set) var replacing = false
    enum DownloadState: Equatable {
        case waiting, downloading, available, failed(String)
        var label: String {
            switch self {
            case .waiting: "Saved · Waiting to download. Magpie will retry automatically."
            case .downloading: "Downloading for offline reading…"
            case .available: "Available offline"
            case .failed(let message): "Download failed: " + message
            }
        }
    }
    struct DownloadKey: Hashable {
        let episodeID: Int
        let contentID: Int?
        init(_ episode: Episode) { episodeID = episode.id; contentID = episode.contentID }
    }
    @Published private(set) var downloads: [DownloadKey: DownloadState] = [:]
    private let api: HearfulAPI
    private let inbox: CaptureInbox
    private let cache: OfflineCache
    private let uploadPDF: (PDFUploadInbox, PDFUploadInbox.Pending) async throws -> Void
    private let announce: (String) -> Void
    private let isSignedIn: () -> Bool
    private var removals = Set<Int>()
    private var captureRemovals = Set<UUID>()
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        api: HearfulAPI = HearfulAPI(), inbox: CaptureInbox = .shared,
        cache: OfflineCache = .shared,
        isSignedIn: @escaping () -> Bool = { KeychainTokenStore.token != nil },
        announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
        uploadPDF: @escaping (PDFUploadInbox, PDFUploadInbox.Pending) async throws -> Void = { try await $0.uploadFromApp($1) }
    ) {
        self.api = api
        self.inbox = inbox
        self.cache = cache
        self.uploadPDF = uploadPDF
        self.announce = announce
        self.isSignedIn = isSignedIn
    }

    private func waitForPreparation() async {
        guard loading || replacing else { return }
        await withCheckedContinuation { preparationWaiters.append($0) }
    }

    private func finishPreparation() {
        let waiters = preparationWaiters
        preparationWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func availability(_ episode: Episode) -> DownloadState {
        downloads[DownloadKey(episode)] ?? .waiting
    }

    private func refreshAvailability() {
        var states = downloads
        for episode in episodes {
            let key = DownloadKey(episode)
            guard states[key] != .downloading else { continue }
            if cache.article(episodeID: episode.id, contentID: episode.contentID) != nil {
                states[key] = .available
            } else if states[key] == .available || states[key] == nil { states[key] = .waiting }
        }
        downloads = states
    }

    var needsRetry: Bool {
        !pending.isEmpty || !pendingPDFs.isEmpty || error != nil || episodes.contains { availability($0) != .available }
    }
    private var generation = 0
    private var schedule = OfflineRetrySchedule()
    func retryIfDue(reset: Bool) async {
        if reset { schedule.reset() }
        if schedule.isDue && needsRetry { await load() }
    }
    private var currentAccount: CaptureInbox.Account? {
        guard let account = inbox.account, account.server == api.baseURL,
            isSignedIn()
        else { return nil }
        return account
    }

    func load() async {
        guard !loading, !replacing, removals.isEmpty, captureRemovals.isEmpty,
            let account = currentAccount else { return }
        let generation = self.generation
        loading = true
        defer {
            if self.generation == generation {
                loading = false
                if needsRetry { schedule.failed() } else { schedule.reset() }
                finishPreparation()
            }
        }
        error = nil
        if let local = cache.load([Episode].self, for: .savedArticles) {
            episodes = OfflineLibraryActions.shared.overlay(local)
        }
        refreshAvailability()
        pending = inbox.pending(for: account)
        let pdfInbox = PDFUploadInbox(directory: inbox.directory)
        pendingPDFs = pdfInbox.pending(for: account)
        for pdf in pendingPDFs {
            do { try await uploadPDF(pdfInbox, pdf) }
            catch {
                guard currentAccount == account, self.generation == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                break
            }
            guard currentAccount == account, self.generation == generation, !Task.isCancelled else { return }
        }
        pendingPDFs = pdfInbox.pending(for: account)
        // Library display and preparation are independent of pending uploads.
        // A slow or bad capture must not hide everything already saved.
        do {
            let loaded = try await api.savedArticles()
            guard currentAccount == account, self.generation == generation, !Task.isCancelled else { return }
            episodes = OfflineLibraryActions.shared.overlay(loaded)
            refreshAvailability()
            for episode in loaded { invalidateReplacedPlayback(episode) }
            cache.save(episodes, for: .savedArticles)
        } catch {
            guard currentAccount == account, self.generation == generation, !Task.isCancelled else { return }
            if (error as? APIError)?.isAuthFailure == true { episodes = []; return }
            self.error = (error as? APIError)?.spokenResponse ?? "Could not refresh saved articles."
        }
        for capture in pending {
            guard currentAccount == account, self.generation == generation, !Task.isCancelled else { return }
            do {
                let episode = try await api.saveArticle(
                    url: capture.url, title: capture.title, html: capture.html,
                    savedAt: capture.createdAt, contentFormat: capture.contentFormat,
                    replaceExisting: capture.replaceExisting == true, createIfMissing: true)
                guard currentAccount == account, self.generation == generation, !Task.isCancelled else { return }
                invalidateReplacedPlayback(episode)
                episodes.removeAll { $0.id == episode.id }
                episodes.insert(episode, at: 0)
                // Retain the capture if the acknowledged metadata cannot be
                // persisted. A failed text download remains visible/retryable.
                guard cache.save(episodes, for: .savedArticles) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                if episode.documentID == nil {
                    if let message = episode.captureError, !message.isEmpty {
                        throw APIError(spokenResponse: message, underlying: "Article preparation failed")
                    }
                    guard episode.hasText == true || episode.contentID != nil else {
                        throw APIError(spokenResponse: "The link is saved, but its text is not ready. Retry from Saved.", underlying: "Article not prepared")
                    }
                }
                // The server save and local metadata are durable. Downloading
                // text is a separate retryable operation, not another save.
                try inbox.remove(capture)
            } catch {
                guard currentAccount == account, self.generation == generation else { return }
                self.error = (error as? APIError)?.spokenResponse ?? error.localizedDescription
                break
            }
        }
        guard currentAccount == account, self.generation == generation else { return }
        pending = inbox.pending(for: account)
        let missing = episodes.filter { ($0.hasText == true || $0.contentID != nil) && availability($0) != .available }
        // At most three downloads in flight, including after reconnection.
        for start in stride(from: 0, to: missing.count, by: 3) {
            guard currentAccount == account, self.generation == generation, !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for episode in missing[start..<min(start + 3, missing.count)] {
                    group.addTask { await self.download(episode) }
                }
            }
        }
    }

    func download(_ episode: Episode) async {
        guard downloads[DownloadKey(episode)] != .downloading, let account = currentAccount else { return }
        if cache.article(episodeID: episode.id, contentID: episode.contentID) != nil {
            downloads[DownloadKey(episode)] = .available
            return
        }
        let generation = self.generation
        downloads[DownloadKey(episode)] = .downloading
        do {
            let text = try await withVoiceDeadline(seconds: 10) { [api] in
                try await api.articleText(episodeID: episode.id, contentID: episode.contentID)
            }
            guard currentAccount == account, self.generation == generation, !Task.isCancelled else { return }
            guard text.episodeID == episode.id, episode.contentID == nil || text.contentID == episode.contentID else {
                throw APIError(underlying: "The server returned a different article version")
            }
            guard cache.saveArticle(text) else { throw CocoaError(.fileWriteUnknown) }
            downloads[DownloadKey(episode)] = .available
        } catch {
            guard currentAccount == account, self.generation == generation else { return }
            if error is CancellationError || error is VoiceTimeout
                || (error as? APIError)?.isRetryableDownload == true {
                downloads[DownloadKey(episode)] = .waiting
            } else {
                downloads[DownloadKey(episode)] = .failed((error as? APIError)?.spokenResponse ?? "Could not store the offline copy.")
            }
        }
    }

    func save(_ episode: Episode) async throws {
        guard let account = currentAccount else { throw CaptureInbox.InboxError.signedOut }
        let generation = self.generation
        let saved = try await api.saveArticle(episodeID: episode.id)
        guard currentAccount == account, self.generation == generation else {
            throw CaptureInbox.InboxError.signedOut
        }
        await download(saved)
        NotificationCenter.default.post(name: .hearfulSavedChanged, object: nil)
    }

    /// Persist before reporting success, including when the reader is offline.
    func queueLink(_ url: URL) throws {
        guard let account = currentAccount else { throw CaptureInbox.InboxError.signedOut }
        try inbox.save(url: url)
        pending = inbox.pending(for: account)
        NotificationCenter.default.post(name: .hearfulSavedChanged, object: nil)
    }

    func prepareQueuedLinks() async {
        // A library refresh may already be uploading an earlier snapshot of
        // the queue. Wait for it so this new link is prepared too.
        await waitForPreparation()
        await load()
    }

    func remove(_ episode: Episode) async {
        guard let account = currentAccount, removals.insert(episode.id).inserted else { return }
        defer { removals.remove(episode.id) }
        let generation = self.generation
        // Let an already submitted save finish before deleting its bookmark, so
        // a late server response cannot recreate a dismissed article.
        await waitForPreparation()
        guard currentAccount == account, self.generation == generation else { return }
        do {
            try await api.removeSavedArticle(id: episode.id)
            guard currentAccount == account, self.generation == generation else { return }
            if let link = episode.link {
                for capture in inbox.pending(for: account) where CaptureInbox.sameArticle(capture.url, link) {
                    try inbox.remove(capture)
                }
            }
            pending = inbox.pending(for: account)
            episodes.removeAll { $0.id == episode.id }
            downloads = downloads.filter { $0.key.episodeID != episode.id }
            error = nil
            cache.save(episodes, for: .savedArticles)
            AccessibilityNotification.Announcement("Removed from Saved: \(episode.title)").post()
        } catch {
            guard currentAccount == account, self.generation == generation else { return }
            self.error = (error as? APIError)?.spokenResponse ?? error.localizedDescription
        }
    }

    func remove(_ capture: CaptureInbox.Capture) async {
        guard currentAccount == capture.account, captureRemovals.insert(capture.id).inserted else { return }
        defer { captureRemovals.remove(capture.id) }
        let generation = self.generation
        await waitForPreparation()
        guard currentAccount == capture.account, self.generation == generation else { return }
        do {
            if inbox.pending(for: capture.account).contains(where: { $0.id == capture.id }) {
                try inbox.remove(capture)
            }
            pending = inbox.pending(for: capture.account)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func file(_ filing: EpisodeFiling, episode: Episode) async {
        if filing == .dismissed {
            // Dismissing this list's bookmark does not claim she read it, or
            // dismiss an independently followed copy from Latest.
            await remove(episode)
        } else if await fileEpisode(filing, episode, api: api) {
            await load()
        }
    }

    func retry(_ episode: Episode) async {
        guard !loading, !replacing, removals.isEmpty, captureRemovals.isEmpty,
            let account = currentAccount else { return }
        let generation = self.generation
        replacing = true
        defer {
            if self.generation == generation {
                replacing = false
                finishPreparation()
            }
        }
        error = nil
        do {
            let updated = try await api.retrySavedArticle(id: episode.id)
            guard currentAccount == account, self.generation == generation else { return }
            if let index = episodes.firstIndex(where: { $0.id == updated.id }) { episodes[index] = updated }
            cache.save(episodes, for: .savedArticles)
            if updated.hasText == true || updated.contentID != nil { await download(updated) }
        } catch {
            guard currentAccount == account, self.generation == generation else { return }
            self.error = (error as? APIError)?.spokenResponse ?? error.localizedDescription
        }
    }

    final class TextReplacement {
        let episode: Episode
        fileprivate let account: CaptureInbox.Account
        fileprivate let generation: Int

        fileprivate init(episode: Episode, account: CaptureInbox.Account, generation: Int) {
            self.episode = episode
            self.account = account
            self.generation = generation
        }
    }

    private weak var latestReplacement: TextReplacement?

    func reviewReplacement(_ episode: Episode) -> TextReplacement? {
        guard let account = currentAccount else { return nil }
        let review = TextReplacement(episode: episode, account: account, generation: generation)
        latestReplacement = review
        return review
    }

    func cancelReplacement(_ review: TextReplacement) {
        if latestReplacement === review { latestReplacement = nil }
    }

    func replace(_ review: TextReplacement) async {
        guard latestReplacement === review, currentAccount == review.account, generation == review.generation else { return }
        latestReplacement = nil
        let episode = review.episode
        guard !loading, !replacing, removals.isEmpty, captureRemovals.isEmpty,
            let account = currentAccount else { return }
        let generation = self.generation
        replacing = true
        defer {
            if self.generation == generation {
                replacing = false
                finishPreparation()
            }
        }
        error = nil
        do {
            let updated = try await api.saveArticle(episodeID: episode.id, replaceExisting: true)
            guard currentAccount == account, self.generation == generation else { return }
            invalidateReplacedPlayback(updated)
            if let index = episodes.firstIndex(where: { $0.id == updated.id }) { episodes[index] = updated }
            cache.save(episodes, for: .savedArticles)
            await download(updated)
            guard currentAccount == account, self.generation == generation else { return }
            let message = "Saved text replaced: \(updated.title)"
            switch availability(updated) {
            case .available: announce(message)
            case .waiting: announce("\(message). Waiting to download for offline reading.")
            case .downloading: announce("\(message). Downloading for offline reading.")
            case .failed(let reason): announce("\(message). Offline download failed. \(reason)")
            }
            NotificationCenter.default.post(name: .hearfulSavedChanged, object: updated)
        } catch {
            guard currentAccount == account, self.generation == generation else { return }
            self.error = (error as? APIError)?.spokenResponse ?? error.localizedDescription
        }
    }

    private func invalidateReplacedPlayback(_ updated: Episode) {
        let player = PlaybackCoordinator.shared
        if let current = player.currentEpisode, current.id == updated.id,
            current.contentID != updated.contentID
        {
            player.clear()
        }
    }

    func clear() {
        generation += 1
        schedule.reset()
        loading = false
        replacing = false
        finishPreparation()
        episodes = []
        downloads = [:]
        pending = []
        pendingPDFs = []
        error = nil
    }
}

struct SavedLinkDraft {
    struct Form: Identifiable {
        let id = UUID()
        let account: CaptureInbox.Account?
    }

    var form: Form?
    var address = ""
    var error: String?
    private var sessionScope: String?

    mutating func open(account: CaptureInbox.Account?, scope: String?) {
        if scope != sessionScope { address = "" }
        sessionScope = scope
        error = nil
        form = Form(account: account)
    }

    mutating func edit(_ address: String, in presented: Form, scope: String?) {
        guard form?.id == presented.id, scope == sessionScope else { return }
        self.address = address
    }

    mutating func save(_ presented: Form, scope: String?, inbox: CaptureInbox = .shared) -> Bool {
        guard form?.id == presented.id, scope == sessionScope else { return false }
        do {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CaptureInbox.InboxError.invalidURL
            }
            try inbox.save(url: url, reviewedBy: presented.account)
            self = SavedLinkDraft()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct SavedView: View {
    @EnvironmentObject private var auth: AuthController
    @Environment(\.scenePhase) private var scenePhase
    @Binding var showingVoice: Bool
    @Binding var openEpisode: Episode?
    @ObservedObject private var model = SavedLibrary.shared
    @ObservedObject private var player = PlaybackCoordinator.shared
    @State private var finished = false
    @State private var query = ""
    @State private var draft = SavedLinkDraft()
    @State private var deletingPDF: SavedPDFActions.DeletionReview?
    @StateObject private var pdfActions = SavedPDFActions()
    @State private var importingPDF = false
    @StateObject private var pdfAccess = SavedPDFAccess()
    @State private var replacing: SavedLibrary.TextReplacement?

    private var visible: [Episode] {
        model.episodes.filter {
            ($0.completed == true) == finished
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || ($0.link?.host?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                OfflineSyncNotice()
                PendingLibraryChanges()
                Picker("Saved articles", selection: $finished) {
                    Text("To read").tag(false)
                    Text("Finished").tag(true)
                }.pickerStyle(.segmented).listRowSeparator(.hidden)
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("Retry saving") { Task { await pdfAccess.refresh(); await model.load() } }
                            .disabled(model.loading)
                    }
                }
                if !finished {
                    ForEach(model.pendingPDFs) { pdf in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pdf.filename.isEmpty ? "PDF document" : pdf.filename)
                            Text("PDF saved on this device · Waiting to upload").font(.caption).foregroundStyle(.secondary)
                            Button("Retry upload") { Task { await model.load() } }.disabled(model.loading)
                        }
                    }
                    ForEach(model.pending) { capture in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capture.displayTitle)
                            Text("Saved on this device · Waiting to sync").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Remove saved link", role: .destructive) {
                                Task { await model.remove(capture) }
                            }
                        }
                    }
                }
                ForEach(visible) { episode in
                    VStack(alignment: .leading, spacing: 6) {
                        EpisodeRow(
                            episode: episode, progress: player.listeningProgress(for: episode),
                            isCurrent: player.currentEpisode?.id == episode.id,
                            play: { player.playReportingFailure(episode) }
                        )
                        .contentShape(Rectangle()).onTapGesture { openEpisode = episode }
                        if (episode.hasText == true || episode.contentID != nil),
                            model.availability(episode) != .available
                        {
                            Text(model.availability(episode).label)
                                .font(.caption).foregroundStyle(.secondary)
                            if model.availability(episode) != .downloading {
                                Button("Retry download") { Task { await model.download(episode) } }
                                    .accessibilityLabel("Retry download: \(episode.title)")
                            }
                        }
                        if let error = episode.captureError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if !episode.preparingPDF { Button("Retry") { Task { await model.retry(episode) } } }
                                if let url = episode.link {
                                    Link("Open original", destination: url)
                                }
                            }.font(.footnote).buttonStyle(.borderless)
                        }
                    }
                    .episodeFilingActions(for: episode, allowsDismissal: true) { filing in
                        Task { await model.file(filing, episode: episode) }
                    }
                    .contextMenu {
                        if let documentID = episode.documentID {
                            if episode.link == nil {
                                Button("View original PDF") { pdfActions.open(documentID) }
                            }
                            Button("Delete PDF", role: .destructive) { deletingPDF = pdfActions.reviewDeletion(documentID) }
                        }
                        if episode.audioURL == nil, episode.link != nil, episode.documentID == nil {
                            Button("Replace saved text", systemImage: "arrow.clockwise") {
                                replacing = model.reviewReplacement(episode)
                            }.disabled(model.loading || model.replacing)
                        }
                        ForEach(
                            EpisodeFiling.available(for: episode, allowsDismissal: false),
                            id: \.self
                        ) { filing in
                            Button {
                                Task { await model.file(filing, episode: episode) }
                            } label: {
                                Label(filing.actionTitle(for: episode), systemImage: filing.systemImage)
                            }
                        }
                        Button("Dismiss from Saved", role: .destructive) {
                            Task { await model.remove(episode) }
                        }
                    }
                }
                // Keep the empty state visible while refreshing an empty library.
                if visible.isEmpty && model.pending.isEmpty && model.pendingPDFs.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet", systemImage: "bookmark",
                        description: Text(
                            finished
                                ? "Articles you finish stay here."
                                : "Share a web page to Magpie, or add a link above."))
                }
            }
            .listStyle(.plain)
            .navigationTitle("Saved")
            .toolbarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search saved articles")
            .confirmationDialog(
                "Replace saved text?",
                isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                titleVisibility: .visible,
                presenting: replacing
            ) { review in
                Button("Replace saved text") { Task { await model.replace(review) } }
                Button("Cancel", role: .cancel) { model.cancelReplacement(review) }
            } message: { _ in
                Text("Download a fresh copy from the original link. If the text changes, listening starts from the beginning. If it fails, your current copy is kept. For pages requiring sign-in, share from Safari to update your saved copy.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .hearfulRetryOffline)) { note in
                Task { await model.retryIfDue(reset: note.object as? Bool == true) }
            }
            .refreshable { await pdfAccess.refresh(); await model.load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add link") { draft.open(account: CaptureInbox.shared.account, scope: ShortcutScope.current) }
                        if pdfAccess.enabled { Button("Import PDF", systemImage: "doc.badge.plus") { importingPDF = true } }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("Add to Saved")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openVoiceSheet($showingVoice)
                    } label: {
                        Image(systemName: "mic.fill")
                    }.accessibilityLabel("Ask Magpie")
                }
            }
            .navigationDestination(item: $openEpisode) { ArticleView(episode: $0) }
            .quickLookPreview(Binding(get: { pdfActions.file }, set: { if $0 == nil { pdfActions.dismiss() } }))
            .onDisappear { pdfActions.dismiss() }
            .alert("PDF could not be updated", isPresented: Binding(get: { pdfActions.error != nil }, set: { if !$0 { pdfActions.error = nil } })) {
                Button("OK") { pdfActions.error = nil }
            } message: { Text(pdfActions.error ?? "") }
            .confirmationDialog("Delete this PDF and its prepared text?", isPresented: Binding(get: { deletingPDF != nil }, set: { if !$0 { deletingPDF = nil } }), presenting: deletingPDF) { review in
                Button("Delete PDF", role: .destructive) { pdfActions.delete(review) { await model.load() } }
                Button("Cancel", role: .cancel) { pdfActions.cancelDeletion(review) }
            }
            .sheet(isPresented: $importingPDF) { PDFImportView() }
            .onChange(of: auth.sessionOwner) { _, _ in
                replacing = nil
                deletingPDF = nil
                pdfActions.dismiss()
                draft = SavedLinkDraft()
            }
            .sheet(item: $draft.form) { presented in
                NavigationStack {
                    Form {
                        TextField("https://example.com/article", text: Binding(
                            get: { draft.form?.id == presented.id ? draft.address : "" },
                            set: { draft.edit($0, in: presented, scope: ShortcutScope.current) }
                        )).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let error = draft.error { Text(error).foregroundStyle(.red) }
                        Text(
                            "The link is kept on this device until Magpie can save and prepare it."
                        ).font(.footnote)
                    }
                    .navigationTitle("Add link")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { if draft.form?.id == presented.id { draft.form = nil } }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                guard draft.save(presented, scope: ShortcutScope.current) else { return }
                                UIAccessibility.post(notification: .announcement, argument: "Link saved on this device")
                                Task { await model.load() }
                            }.disabled(draft.address.isEmpty)
                        }
                    }
                }.presentationDetents([.medium])
            }
        }
        .task {
            await pdfAccess.refresh()
            await model.load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if model.episodes.contains(where: \.preparingPDF) { await model.load() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hearfulPositionReported)) { note in
            guard let report = note.object as? PositionReport,
                let index = model.episodes.firstIndex(where: {
                    $0.id == report.episodeID && $0.contentID == report.contentID
                })
            else { return }
            model.episodes[index].positionSeconds = report.seconds
            model.episodes[index].completed = report.completed
            OfflineCache.shared.save(model.episodes, for: .savedArticles)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await pdfAccess.refresh(); await model.load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hearfulSavedChanged)) { _ in
            Task { await pdfAccess.refresh(); await model.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hearfulEpisodeFiled)) { _ in
            Task { await model.load() }
        }
    }

}

struct SaveArticleButton: View {
    let episode: Episode
    @State private var saved = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        Button {
            saving = true
            Task {
                do {
                    try await SavedLibrary.shared.save(episode)
                    saved = true
                    UIAccessibility.post(notification: .announcement, argument: "Saved to Magpie")
                } catch {
                    self.error = (error as? APIError)?.spokenResponse ?? error.localizedDescription
                }
                saving = false
            }
        } label: {
            Image(systemName: saved || episode.savedAt != nil ? "bookmark.fill" : "bookmark")
        }
        .disabled(saving)
        .accessibilityLabel(saved || episode.savedAt != nil ? "Saved to Magpie" : "Save for later")
        .alert(
            "Could not save article",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}
