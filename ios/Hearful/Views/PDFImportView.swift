import SwiftUI
import UniformTypeIdentifiers

struct PDFImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var capability: PDFCapability?
    @State private var error: String?
    @State private var busy = false
    @State private var choosing = false
    @State private var account = CaptureInbox.shared.account
    @State private var session = CaptureSessionStore.read()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Save a PDF from Files, or share a PDF link from your browser to Magpie. Preparation continues after the server accepts it.")
                    Text("Datalab receives the PDF or its source link to extract readable text and images. Your imported PDFs remain private to your Magpie account.")
                    Text("Up to 25 MiB and 200 pages per PDF. Password-protected files are not supported.").font(.footnote)
                }
                if let capability {
                    if capability.enabled {
                        if capability.consented {
                            Button("Choose PDF", systemImage: "doc.badge.plus") { choosing = true }.disabled(busy)
                            Button("Stop allowing PDF processing", role: .destructive) { Task { await setConsent(false) } }.disabled(busy)
                        } else {
                            Button("Allow Datalab to process PDFs") { Task { await setConsent(true) } }.disabled(busy)
                        }
                        if let account {
                            ForEach(PDFUploadInbox.shared.pending(for: account)) { item in
                                VStack(alignment: .leading) {
                                    Text(item.filename)
                                    Button("Retry upload") { Task { await upload(item) } }.disabled(busy)
                                    Button("Remove local PDF", role: .destructive) {
                                        try? PDFUploadInbox.shared.remove(item)
                                        Task { await load() }
                                    }.disabled(busy)
                                }
                            }
                        }
                    } else {
                        Text("PDF importing is not enabled for this account.")
                    }
                }
                if busy { ProgressView("Saving PDF…") }
                if let error { Text(error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
            }
            .navigationTitle("Import PDF")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { result in
                Task {
                    do {
                        guard let account, CaptureInbox.shared.account == account else { throw CaptureUploader.Failure.changedAccount }
                        let url = try result.get()
                        let data = try await Task.detached { try PDFUploadInbox.readFile(url) }.value
                        guard CaptureInbox.shared.account == account else { throw CaptureUploader.Failure.changedAccount }
                        let pending = try PDFUploadInbox.shared.save(data, filename: url.lastPathComponent, account: account)
                        await upload(pending)
                    } catch { self.error = error.localizedDescription }
                }
            }
        }.task { await load() }
    }

    private func load() async {
        do { capability = try await request("capability") }
        catch { self.error = error.localizedDescription }
    }
    private func setConsent(_ granted: Bool) async {
        busy = true
        defer { busy = false }
        do { capability = try await request("consent", granted: granted); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func upload(_ item: PDFUploadInbox.Pending) async {
        busy = true
        defer { busy = false }
        do {
            try await PDFUploadInbox.shared.upload(item)
            guard CaptureInbox.shared.account == account else { return }
            NotificationCenter.default.post(name: .hearfulSavedChanged, object: nil)
            UIAccessibility.post(notification: .announcement, argument: "PDF saved. Preparing for reading in Magpie.")
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func request(_ path: String, granted: Bool? = nil) async throws -> PDFCapability {
        guard let session, CaptureSessionStore.read() == session else { throw CaptureUploader.Failure.changedAccount }
        var request = URLRequest(url: session.account.server.appendingPathComponent("documents/\(path)"))
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        if let granted {
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["granted": granted])
        }
        let (data, response) = try await CaptureUploader.send(request)
        guard CaptureSessionStore.read() == session else { throw CaptureUploader.Failure.changedAccount }
        guard response.statusCode == 200 else { throw PDFUploadInbox.Failure.message("PDF importing is unavailable for this account or server.") }
        return try JSONDecoder().decode(PDFCapability.self, from: data)
    }
}

nonisolated struct PDFCapability: Decodable {
    let enabled: Bool
    let consented: Bool
}
