import Foundation

/// A foreground Saved refresh and the import dialog can pick up the same queue entry.
actor PDFUploadRequests {
    static let shared = PDFUploadRequests()
    private var uploads: [URL: Task<Void, Error>] = [:]

    func start(file: URL, upload: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        if let existing = uploads[file] { return existing }
        let task = Task {
            defer { uploads[file] = nil }
            try await upload()
        }
        uploads[file] = task
        return task
    }
}

extension PDFUploadInbox {
    func uploadFromApp(_ item: Pending) async throws {
        guard let directory else { throw CaptureInbox.InboxError.unavailable }
        let file = directory.appendingPathComponent("pdf-\(item.id).pdf")
        let task = await PDFUploadRequests.shared.start(file: file) { try await upload(item) }
        try await task.value
    }
}
