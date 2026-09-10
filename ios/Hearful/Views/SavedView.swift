import SwiftUI

extension Notification.Name {
    nonisolated static let hearfulSavedChanged = Notification.Name("hearfulSavedChanged")
}

@MainActor
final class SavedLibrary: ObservableObject {
    static let shared = SavedLibrary()
    @Published var episodes: [Episode] = []
    @Published var pending: [CaptureInbox.Capture] = []
    @Published var error: String?
    @Published var loading = false
    @Published private(set) var replacing = false
    private let api = HearfulAPI()
    private var generation = 0
    private var currentAccount: CaptureInbox.Account? {
        guard let account = CaptureInbox.shared.account, account.server == api.baseURL,
            KeychainTokenStore.token != nil
        else { return nil }
        return account
    }

    func load() async {
        guard !loading, !replacing, let account = currentAccount else { return }
        let generation = self.generation
        loading = true
        defer { if self.generation == generation { loading = false } }
        error = nil
        do {
            pending = CaptureInbox.shared.pending(for: account)
            for capture in pending {
                guard currentAccount == account, self.generation == generation else { return }
                do {
                    let episode = try await api.saveArticle(
                        url: capture.url, title: capture.title, html: capture.html,
                        savedAt: capture.createdAt, contentFormat: capture.contentFormat,
                        replaceExisting: capture.replaceExisting == true)
                    // Signing out or switching servers during a request must not
                    // write the previous account's response into the next cache.
                    guard currentAccount == account, self.generation == generation else { return }
                    invalidateReplacedPlayback(episode)
                    await download(episode)
                    guard currentAccount == account, self.generation == generation else { return }
                    try CaptureInbox.shared.remove(capture)
                } catch {
                    guard currentAccount == account, self.generation == generation else { return }
                    self.error = (error as? APIError)?.spokenResponse ?? error.localizedDescription
                    break
                }
            }
            pending = CaptureInbox.shared.pending(for: account)
        }
        guard currentAccount == account, self.generation == generation else { return }
        do {
            let loaded = try await api.savedArticles()
            guard currentAccount == account, self.generation == generation else { return }
            episodes = loaded
            for episode in loaded { invalidateReplacedPlayback(episode) }
            OfflineCache.shared.save(loaded, for: .savedArticles)
            for episode in loaded where episode.contentID != nil {
                guard currentAccount == account, self.generation == generation else { return }
                await download(episode)
            }
        } catch {
            guard currentAccount == account, self.generation == generation else { return }
            episodes = OfflineCache.shared.load([Episode].self, for: .savedArticles) ?? []
            self.error = (error as? APIError)?.spokenResponse ?? "Could not load saved articles."
        }
    }

    func download(_ episode: Episode) async {
        guard let contentID = episode.contentID else { return }
        let key = OfflineCache.Key.articleVersion(episodeID: episode.id, contentID: contentID)
        guard OfflineCache.shared.load(EpisodeText.self, for: key) == nil else { return }
        guard let account = currentAccount else { return }
        let generation = self.generation
        if let text = try? await api.articleText(episodeID: episode.id, contentID: contentID),
            currentAccount == account, self.generation == generation
        {
            OfflineCache.shared.save(text, for: key)
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

    func remove(_ episode: Episode) async {
        guard let account = currentAccount else { return }
        let generation = self.generation
        do {
            try await api.removeSavedArticle(id: episode.id)
            guard currentAccount == account, self.generation == generation else { return }
            episodes.removeAll { $0.id == episode.id }
            OfflineCache.shared.save(episodes, for: .savedArticles)
            AccessibilityNotification.Announcement("Removed from Saved: \(episode.title)").post()
        } catch { self.error = (error as? APIError)?.spokenResponse ?? error.localizedDescription }
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
        do {
            _ = try await api.retrySavedArticle(id: episode.id)
            await load()
        } catch { self.error = (error as? APIError)?.spokenResponse ?? error.localizedDescription }
    }

    func replace(_ episode: Episode) async {
        guard !loading, !replacing, let account = currentAccount else { return }
        let generation = self.generation
        replacing = true
        defer { if self.generation == generation { replacing = false } }
        do {
            let updated = try await api.saveArticle(episodeID: episode.id, replaceExisting: true)
            guard currentAccount == account, self.generation == generation else { return }
            invalidateReplacedPlayback(updated)
            if let index = episodes.firstIndex(where: { $0.id == updated.id }) { episodes[index] = updated }
            OfflineCache.shared.save(episodes, for: .savedArticles)
            await download(updated)
            guard currentAccount == account, self.generation == generation else { return }
            AccessibilityNotification.Announcement("Saved text replaced: \(updated.title)").post()
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
        loading = false
        replacing = false
        episodes = []
        pending = []
        error = nil
    }
}

struct SavedView: View {
    @Binding var showingVoice: Bool
    @Binding var openEpisode: Episode?
    @ObservedObject private var model = SavedLibrary.shared
    @ObservedObject private var player = PlaybackCoordinator.shared
    @State private var finished = false
    @State private var query = ""
    @State private var adding = false
    @State private var link = ""
    @State private var addError: String?
    @State private var replacing: Episode?

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
                Picker("Saved articles", selection: $finished) {
                    Text("To read").tag(false)
                    Text("Finished").tag(true)
                }.pickerStyle(.segmented).listRowSeparator(.hidden)
                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                if !finished {
                    ForEach(model.pending) { capture in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capture.title ?? capture.url.host ?? "Saved link")
                            Text("Saved on this device · Waiting to sync").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Remove saved link", role: .destructive) {
                                do {
                                    try CaptureInbox.shared.remove(capture)
                                    Task { await model.load() }
                                } catch { model.error = error.localizedDescription }
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
                        if let error = episode.captureError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Retry") { Task { await model.retry(episode) } }
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
                        if episode.audioURL == nil, episode.link != nil {
                            Button("Replace saved text", systemImage: "arrow.clockwise") {
                                replacing = episode
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
                if visible.isEmpty && model.pending.isEmpty && !model.loading {
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
            ) { episode in
                Button("Replace saved text") { Task { await model.replace(episode) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Download a fresh copy from the original link. If the text changes, listening starts from the beginning. If it fails, your current copy is kept. For pages requiring sign-in, share from Safari and choose Replace saved text.")
            }
            .refreshable { await model.load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                    }.accessibilityLabel("Add link")
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
            .sheet(isPresented: $adding) {
                NavigationStack {
                    Form {
                        TextField("https://example.com/article", text: $link).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let addError { Text(addError).foregroundStyle(.red) }
                        Text(
                            "The link is kept on this device until Magpie can save and prepare it."
                        ).font(.footnote)
                    }
                    .navigationTitle("Add link")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { adding = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                do {
                                    guard
                                        let url = URL(
                                            string: link.trimmingCharacters(
                                                in: .whitespacesAndNewlines))
                                    else { throw CaptureInbox.InboxError.invalidURL }
                                    try CaptureInbox.shared.save(url: url)
                                    link = ""
                                    addError = nil
                                    adding = false
                                    UIAccessibility.post(
                                        notification: .announcement,
                                        argument: "Link saved on this device")
                                    Task { await model.load() }
                                } catch { addError = error.localizedDescription }
                            }.disabled(link.isEmpty)
                        }
                    }
                }.presentationDetents([.medium])
            }
        }
        .task { await model.load() }
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
        .onReceive(NotificationCenter.default.publisher(for: .hearfulSavedChanged)) { _ in
            Task { await model.load() }
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
