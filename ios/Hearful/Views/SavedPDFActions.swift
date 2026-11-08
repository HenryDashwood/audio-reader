import SwiftUI

@MainActor
final class SavedPDFActions: ObservableObject {
    @Published private(set) var file: URL?
    @Published var error: String?
    private let session: () -> CaptureSessionStore.Session?
    private let send: (URLRequest) async throws -> (Data, HTTPURLResponse)
    private var generation = 0
    private var preview: Task<Void, Never>?
    private struct Deletion: Equatable {
        let session: CaptureSessionStore.Session
        let documentID: String
    }
    private var deletions: [Deletion] = []

    final class DeletionReview {
        fileprivate let session: CaptureSessionStore.Session
        fileprivate let documentID: String

        fileprivate init(session: CaptureSessionStore.Session, documentID: String) {
            self.session = session
            self.documentID = documentID
        }
    }
    private weak var latestReview: DeletionReview?

    func reviewDeletion(_ id: String) -> DeletionReview? {
        guard let credentials = session() else { return nil }
        let review = DeletionReview(session: credentials, documentID: id)
        latestReview = review
        return review
    }

    func cancelDeletion(_ review: DeletionReview) {
        if latestReview === review { latestReview = nil }
    }

    init(session: @escaping () -> CaptureSessionStore.Session? = { CaptureSessionStore.read() },
         send: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse) = CaptureUploader.send) {
        self.session = session
        self.send = send
    }

    func dismiss() {
        latestReview = nil
        generation += 1
        preview?.cancel()
        preview = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        error = nil
    }

    @discardableResult
    func open(_ id: String) -> Task<Void, Never>? {
        dismiss()
        guard let credentials = session() else { return nil }
        let attempt = generation
        let task = Task {
            do {
                let data = try await request(id, credentials: credentials, delete: false)
                guard generation == attempt, session() == credentials else { return }
                let url = URL.temporaryDirectory.appendingPathComponent("Magpie-\(UUID().uuidString).pdf")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                file = url
            } catch {
                guard generation == attempt, session() == credentials else { return }
                self.error = error.localizedDescription
            }
        }
        preview = task
        return task
    }

    @discardableResult
    func delete(_ review: DeletionReview, refresh: @escaping () async -> Void) -> Task<Void, Never>? {
        guard latestReview === review, session() == review.session else { return nil }
        latestReview = nil
        let credentials = review.session
        let id = review.documentID
        let deletion = Deletion(session: credentials, documentID: id)
        guard !deletions.contains(deletion) else { return nil }
        deletions.append(deletion)
        dismiss()
        let attempt = generation
        return Task {
            defer { deletions.removeAll { $0 == deletion } }
            guard session() == credentials else { return }
            do {
                _ = try await request(id, credentials: credentials, delete: true)
                if session() == credentials { await refresh() }
            } catch {
                if generation == attempt, session() == credentials { self.error = error.localizedDescription }
            }
        }
    }

    private func request(_ id: String, credentials: CaptureSessionStore.Session, delete: Bool) async throws -> Data {
        var url = credentials.account.server.appendingPathComponent("documents").appendingPathComponent(id)
        if !delete { url.appendPathComponent("original") }
        var request = URLRequest(url: url)
        request.httpMethod = delete ? "DELETE" : "GET"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw PDFUploadInbox.Failure.message("The PDF could not be opened or deleted. Please retry.")
        }
        return data
    }
}
