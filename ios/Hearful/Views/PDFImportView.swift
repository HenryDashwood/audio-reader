import SwiftUI
import UniformTypeIdentifiers

struct PDFImportView: View {
    @EnvironmentObject private var auth: AuthController

    var body: some View {
        PDFAccountImportView(session: Self.currentSession)
            .id(auth.sessionOwner)
    }

    fileprivate static var currentSession: CaptureSessionStore.Session? {
        guard let session = CaptureSessionStore.read(),
              ShortcutScope.forToken(session.token, server: session.account.server) == ShortcutScope.current else { return nil }
        return session
    }
}

private struct PDFAccountImportView: View {
    let session: CaptureSessionStore.Session?
    private var account: CaptureInbox.Account? { session?.account }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var access = SavedPDFAccess()
    @State private var error: String?
    @State private var busy = false
    @State private var presentation = ShareSheetUpload()
    @State private var choosing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Save a PDF from Files, or share a PDF link from your browser to Magpie. Preparation continues after the server accepts it.")
                    Text("Datalab receives the PDF or its source link to extract readable text and images. Your imported PDFs remain private to your Magpie account.")
                    Text("Up to 25 MiB and 200 pages per PDF. Password-protected files are not supported.").font(.footnote)
                }
                if let capability = access.capability {
                    if capability.enabled {
                        Button("Choose PDF", systemImage: "doc.badge.plus") { choosing = true }.disabled(busy)
                        if let account {
                            ForEach(PDFUploadInbox.shared.pending(for: account)) { item in
                                VStack(alignment: .leading) {
                                    Text(item.filename)
                                    Button("Retry upload") { upload { item } }.disabled(busy)
                                    Button("Remove local PDF", role: .destructive) {
                                        guard !presentation.isDismissed, session == PDFImportView.currentSession else { return }
                                        do {
                                            try PDFUploadInbox.shared.remove(item)
                                            error = nil
                                            Task { await load() }
                                        } catch {
                                            self.error = error.localizedDescription
                                        }
                                    }.disabled(busy)
                                }
                            }
                        }
                    } else {
                        if capability.subscription_available == true {
                            NavigationLink("Get Magpie Plus") { PlusView() }
                        } else {
                            Text("PDF importing is not available yet.")
                        }
                    }
                }
                if access.canCheckAgain {
                    Button("Check access") {
                        error = nil
                        Task { await load() }
                    }
                }
                if busy { ProgressView("Saving PDF…") }
                if let error = error ?? access.error { Text(error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
            }
            .navigationTitle("Import PDF")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { presentation.dismiss(cancelUpload: false); dismiss() } } }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { [presentation] result in
                guard let result = PDFPickerResult.accept(result, for: session, current: PDFImportView.currentSession, presentation: presentation) else { return }
                guard case .success(let url) = result else {
                    if case .failure(let failure) = result {
                        error = failure.localizedDescription
                    }
                    return
                }
                upload {
                    guard let account, CaptureInbox.shared.account == account else { throw CaptureUploader.Failure.changedAccount }
                    let data = try await Task.detached { try PDFUploadInbox.readFile(url) }.value
                    guard session == PDFImportView.currentSession, CaptureInbox.shared.account == account else { throw CaptureUploader.Failure.changedAccount }
                    return try PDFUploadInbox.shared.save(data, filename: url.lastPathComponent, account: account)
                }
            }
        }.onAppear {
            if presentation.isDismissed {
                presentation = ShareSheetUpload()
                busy = false
            }
        }
        .onDisappear { presentation.dismiss(cancelUpload: false) }
        .task { await load() }
    }

    private func load() async {
        let owner = presentation
        guard !owner.isDismissed else { return }
        guard let session else {
            error = CaptureUploader.Failure.signIn.localizedDescription
            return
        }
        await access.refresh(account: {
            !owner.isDismissed && session == PDFImportView.currentSession ? session.account : nil
        })
    }
    private func upload(_ prepare: @escaping @MainActor () async throws -> PDFUploadInbox.Pending) {
        guard !presentation.isDismissed, presentation.task == nil, let session,
              PDFImportView.currentSession == session else { return }
        busy = true
        error = nil
        presentation.start {
            let item = try await prepare()
            try await PDFUploadInbox.shared.uploadFromApp(item)
            if PDFImportView.currentSession == session {
                NotificationCenter.default.post(name: .hearfulSavedChanged, object: nil)
            }
        } completion: { result in
            busy = false
            guard PDFImportView.currentSession == session else { return }
            switch result {
            case .success:
                UIAccessibility.post(notification: .announcement, argument: "PDF saved. Preparing for reading in Magpie.")
                dismiss()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

@MainActor
enum PDFPickerResult {
    static func accept(_ result: Result<URL, Error>, for session: CaptureSessionStore.Session?,
                       current: CaptureSessionStore.Session?, presentation: ShareSheetUpload) -> Result<URL, Error>? {
        guard let session, current == session, !presentation.isDismissed else { return nil }
        if case .failure(let error) = result, (error as NSError).domain == NSCocoaErrorDomain,
           (error as NSError).code == NSUserCancelledError { return nil }
        return result
    }
}
