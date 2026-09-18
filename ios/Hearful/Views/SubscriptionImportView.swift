import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SubscriptionImportModel: ObservableObject {
    @Published private(set) var job: SubscriptionImportJob?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published var selected: Set<Int> = []
    private let api: any SubscriptionImportAPI
    private let validSession: () -> Bool
    private var generation = 0
    private var pendingStart: (id: String, entries: [Int], request: String)?
    private var pendingRetry: (id: String, request: String)?
    var uncertainStart: Bool { pendingStart != nil }

    init(api: any SubscriptionImportAPI = SubscriptionImportClient(), validSession: @escaping () -> Bool = { true }) {
        self.api = api
        self.validSession = validSession
    }
    func invalidate() {
        generation += 1
        job = nil
        selected = []
        pendingStart = nil
        pendingRetry = nil
        busy = false
        error = nil
    }
    private func accept(_ value: SubscriptionImportJob?) {
        let changed = job?.id != value?.id
        let previousAdded = job?.added ?? 0
        job = value
        if changed {
            selected = Set(value?.items.filter { $0.status == "ready" }.map(\.id) ?? [])
        }
        if value == nil || changed || value?.draft == false { pendingStart = nil }
        if (value?.added ?? 0) > previousAdded {
            NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
        }
    }
    private func perform(_ work: () async throws -> SubscriptionImportJob?) async {
        guard !busy, validSession() else { return }
        busy = true
        error = nil
        let ticket = generation
        defer { if ticket == generation { busy = false } }
        do {
            let value = try await work()
            guard ticket == generation, validSession(), !Task.isCancelled else { return }
            accept(value)
        } catch is CancellationError {
        } catch {
            guard ticket == generation, validSession(), !Task.isCancelled else { return }
            self.error = (error as? APIError)?.spokenResponse ?? "The import couldn't connect. Please try again."
        }
    }
    func load() async { await perform { try await api.current() } }
    func preview(_ data: Data) async {
        guard pendingStart == nil else { return }
        await perform { try await api.preview(data) }
    }
    func start() async {
        guard let job, job.draft, !selected.isEmpty else { return }
        if pendingStart == nil { pendingStart = (job.id, selected.sorted(), UUID().uuidString) }
        guard let pendingStart else { return }
        await perform { try await api.start(id: pendingStart.id, entries: pendingStart.entries, requestID: pendingStart.request) }
    }
    func stop() async {
        guard let job else { return }
        await perform { try await api.stop(id: job.id) }
    }
    func retry() async {
        guard let job else { return }
        if pendingRetry == nil { pendingRetry = (job.id, UUID().uuidString) }
        guard let attempt = pendingRetry else { return }
        await perform { try await api.retry(id: attempt.id, requestID: attempt.request) }
        if self.job?.id != attempt.id { pendingRetry = nil }
    }
    func chooseAnother() { guard !busy, pendingStart == nil else { return }; job = nil; selected = [] }
    func fileError() { error = "This file couldn't be opened. Choose an OPML file smaller than 5 MiB." }
}

struct SubscriptionImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: SubscriptionImportModel
    @State private var choosingFile = false
    @State private var query = ""
    private let onFollowing: () -> Void
    private let initialToken: String?
    private let initialServer: URL

    init(onFollowing: @escaping () -> Void = { ShortcutNavigation.request(.destination(.following)) }) {
        let token = KeychainTokenStore.token
        let server = AppConfiguration.apiBaseURL
        initialToken = token
        initialServer = server
        self.onFollowing = onFollowing
        _model = StateObject(wrappedValue: SubscriptionImportModel(
            api: SubscriptionImportClient(baseURL: server, token: token),
            validSession: { KeychainTokenStore.token == token && AppConfiguration.apiBaseURL == server }))
    }

    var body: some View {
        List {
            if let job = model.job {
                if job.draft { review(job) }
                else if job.active { progress(job) }
                else { results(job) }
            } else {
                Section {
                    Text("Bring the podcasts and publications you follow into Magpie.")
                    Button("Choose OPML file") { choosingFile = true }
                        .accessibilityIdentifier("choose-opml")
                } footer: {
                    Text("This imports subscriptions. Reading and listening history aren’t included.")
                }
                Section {
                    DisclosureGroup("How to export from your app") {
                        Text("In your podcast or RSS reader app, look for Export subscriptions or Export OPML. Save the file to Files, then choose it here.")
                        Link("Pocket Casts instructions", destination: URL(string: "https://support.pocketcasts.com/knowledge-base/opml-export/")!)
                        Link("Feedly instructions", destination: URL(string: "https://docs.feedly.com/article/52-how-can-i-export-my-sources-and-feeds-through-opml")!)
                        Link("Readwise Reader instructions", destination: URL(string: "https://docs.readwise.io/reader/docs/faqs/exporting")!)
                    }
                }
            }
            if model.busy { ProgressView("Updating import…") }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Check import status") { Task { await model.load() } }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.xml, .data], allowsMultipleSelection: false) { result in
            Task {
                do {
                    guard let url = try result.get().first else { return }
                    let data = try await Self.readFile(url)
                    await model.preview(data)
                } catch { model.fileError() }
            }
        }
        .task { await model.load() }
        .task(id: "\(model.job?.id ?? "none")-\(model.job?.active == true)-\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            while model.job?.active == true && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(model.error == nil ? 3 : 10)) } catch { break }
                await model.load()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if KeychainTokenStore.token != initialToken || AppConfiguration.apiBaseURL != initialServer {
                    model.invalidate(); dismiss()
                } else { Task { await model.load() } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hearfulServerChanged)) { _ in model.invalidate(); dismiss() }
        .onChange(of: model.job?.status) { previous, current in
            if current == "queued" || current == "completed" || current == "stopped" {
                AccessibilityNotification.Announcement(title).post()
            }
        }
        .onChange(of: model.error) { _, value in
            if let value { AccessibilityNotification.Announcement(value).post() }
        }
    }
    private var title: String {
        guard let job = model.job else { return "Import subscriptions" }
        if job.draft { return "Review subscriptions" }
        if job.active { return "Importing subscriptions" }
        if job.status == "stopped" { return "Import stopped" }
        return job.failed > 0 ? "Import finished with issues" : "Import complete"
    }
    @ViewBuilder private func review(_ job: SubscriptionImportJob) -> some View {
        Section {
            if job.items.count > 20 { TextField("Search subscriptions", text: $query) }
            Button(model.selected.isEmpty ? "Select all" : "Deselect all") {
                model.selected = model.selected.isEmpty ? Set(job.items.filter { $0.status == "ready" }.map(\.id)) : []
            }.disabled(model.busy || model.uncertainStart)
            ForEach(job.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { item in
                if item.status == "ready" {
                    Toggle(isOn: Binding(get: { model.selected.contains(item.id) }, set: {
                        if $0 { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
                    })) {
                        VStack(alignment: .leading) { Text(item.title); Text(item.host).font(.caption).foregroundStyle(.secondary) }
                    }.disabled(model.busy || model.uncertainStart)
                } else {
                    VStack(alignment: .leading) {
                        Text(item.title)
                        Text(item.message ?? "Already following").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section {
            Text("Personalised feeds stay private to your account. If we can’t confirm a feed is public, we import it privately.")
                .font(.footnote).foregroundStyle(.secondary)
            Button(model.uncertainStart ? "Retry import request" : "Import \(model.selected.count) \(model.selected.count == 1 ? "subscription" : "subscriptions")") {
                Task { await model.start() }
            }.disabled(model.busy || model.selected.isEmpty)
            Button("Choose another file") { model.chooseAnother(); choosingFile = true }
                .disabled(model.busy || model.uncertainStart)
        } footer: {
            Text("New episodes and articles will appear in Latest. Older items stay available on each subscription’s page.")
        }
        if job.duplicates > 0 { Text("\(job.duplicates) \(job.duplicates == 1 ? "duplicate entry was" : "duplicate entries were") skipped.").font(.footnote) }
        if job.folders { Text("Folder organisation won’t be imported.").font(.footnote) }
    }
    @ViewBuilder private func progress(_ job: SubscriptionImportJob) -> some View {
        Section {
            ProgressView(value: Double(job.finished), total: Double(max(1, job.total))) {
                Text("\(job.finished) of \(job.total) subscriptions checked")
            }
            Text("You can leave this screen. Magpie will keep importing.")
            if let item = job.items.first(where: { $0.status == "processing" }) { Text(item.title) }
            if let message = job.items.first(where: { $0.status == "pending" && $0.message != nil })?.message { Text(message) }
            Button("Go to Following") { onFollowing(); dismiss() }
            Button("Stop import", role: .destructive) { Task { await model.stop() } }.disabled(model.busy)
        }
    }
    @ViewBuilder private func results(_ job: SubscriptionImportJob) -> some View {
        Section {
            LabeledContent("Added", value: "\(job.added)")
            LabeledContent("Already following", value: "\(job.alreadyFollowing)")
            if job.failed > 0 { LabeledContent("Couldn’t import", value: "\(job.failed)") }
            if job.notImported > 0 { LabeledContent("Not imported", value: "\(job.notImported)") }
            Button("Go to Following") { onFollowing(); dismiss() }
            if job.items.contains(where: { $0.status == "failed" && $0.retryable }) {
                Button("Retry failed") { Task { await model.retry() } }.disabled(model.busy)
            }
            Button("Import another file") { model.chooseAnother(); choosingFile = true }.disabled(model.busy)
        }
        if job.failed > 0 {
            Section("Couldn’t import") {
                ForEach(job.items.filter { $0.status == "failed" }) { item in
                    VStack(alignment: .leading) { Text(item.title); Text(item.message ?? "Try again later.").font(.footnote) }
                }
            }
        }
    }
    nonisolated static func readFile(_ url: URL) async throws -> Data {
        try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 5 * 1024 * 1024 + 1) ?? Data()
            guard !data.isEmpty, data.count <= 5 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            return data
        }.value
    }
}
