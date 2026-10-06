import SwiftUI
import UniformTypeIdentifiers

nonisolated struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
    static var writableContentTypes: [UTType] { [contentType] }
    static var contentType: UTType { UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
final class SubscriptionExportModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var document: OPMLDocument?
    @Published private(set) var error: String?
    private let api: any SubscriptionExportAPI
    private let validSession: () async -> Bool
    private var generation = 0

    init(api: any SubscriptionExportAPI, validSession: @escaping () async -> Bool = { true }) {
        self.api = api
        self.validSession = validSession
    }
    func clear() { generation += 1; document = nil; error = nil; busy = false }
    func prepare() async {
        guard !busy else { return }
        let ticket = generation
        busy = true; error = nil; document = nil
        defer { if ticket == generation { busy = false } }
        guard await validSession(), ticket == generation, !Task.isCancelled else {
            if ticket == generation { error = "Your account changed. Reopen Export subscriptions to try again." }
            return
        }
        do {
            let data = try await api.export()
            let valid = await validSession()
            guard ticket == generation, !Task.isCancelled else { return }
            guard valid else { self.error = "Your account changed. Reopen Export subscriptions to try again."; return }
            document = OPMLDocument(data: data)
        } catch {
            let valid = await validSession()
            guard ticket == generation, !Task.isCancelled else { return }
            guard valid else { self.error = "Your account changed. Reopen Export subscriptions to try again."; return }
            self.error = (error as? APIError)?.spokenResponse ?? "Subscriptions couldn’t be exported. Please try again."
        }
    }
}

struct SubscriptionExportView: View {
    private let loadSession: @Sendable () async -> SubscriptionSession

    init(loadSession: @escaping @Sendable () async -> SubscriptionSession = { await SubscriptionSession.capture() }) {
        self.loadSession = loadSession
    }

    var body: some View {
        SubscriptionSessionView(title: "Export subscriptions", loadSession: loadSession) {
            SubscriptionExportSessionView(session: $0)
        }
    }
}

private struct SubscriptionExportSessionView: View {
    @EnvironmentObject private var auth: AuthController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: SubscriptionExportModel
    @State private var saving = false
    @State private var result: String?
    private let session: SubscriptionSession

    init(session: SubscriptionSession) {
        self.session = session
        _model = StateObject(wrappedValue: SubscriptionExportModel(
            api: SubscriptionExportClient(baseURL: session.server, token: session.token),
            validSession: { await session.isCurrent() }))
    }
    var body: some View {
        List {
            Section {
                Text("Save your podcasts and RSS publications as an OPML file to use in another app.")
                Button("Export OPML file") {
                    result = nil
                    Task {
                        await model.prepare()
                        if model.document != nil { saving = true }
                    }
                }.disabled(model.busy || saving)
                if model.busy { ProgressView("Preparing export…") }
            } footer: {
                Text("The file includes any personal feed links. Email-only subscriptions and reading or listening history aren’t included.")
            }
            if let message = model.error ?? result { Section { Text(message) } }
        }
        .navigationTitle("Export subscriptions")
        .fileExporter(isPresented: $saving, document: model.document,
                      contentType: OPMLDocument.contentType, defaultFilename: "Magpie-subscriptions.opml") { outcome in
            switch outcome {
            case .success: result = "Subscriptions exported."
            case .failure: result = "The file couldn’t be saved. Please try again."
            }
            model.clear()
        }
        .onChange(of: auth.user?.id) { _, _ in invalidate() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let valid = await session.isCurrent()
            guard !Task.isCancelled else { return }
            if !valid { invalidate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hearfulServerChanged)) { _ in invalidate() }
        .onChange(of: model.error ?? result) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .onDisappear { if !saving { model.clear() } }
    }
    private func invalidate() { model.clear(); saving = false; dismiss() }
}
