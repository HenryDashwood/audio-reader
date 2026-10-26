import Foundation

/// A separate file queue keeps large PDFs out of the small JSON article inbox.
nonisolated struct PDFUploadInbox: Sendable {
    static let shared = PDFUploadInbox(directory: CaptureInbox.shared.directory)
    static let maxBytes = 25 * 1024 * 1024
    let directory: URL?

    struct Pending: Codable, Identifiable, Sendable {
        let id: UUID
        let account: CaptureInbox.Account
        let filename: String
    }

    static func readFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= maxBytes else { throw Failure.message("Choose a PDF no larger than 25 MiB.") }
            data.append(chunk)
        }
        guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { throw Failure.message("Choose a valid PDF file.") }
        return data
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
    }

    func save(_ data: Data, filename: String, account: CaptureInbox.Account) throws -> Pending {
        guard let directory, data.count <= Self.maxBytes else { throw CaptureInbox.InboxError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = Pending(id: UUID(), account: account, filename: String(filename.prefix(500)))
        try data.write(to: directory.appendingPathComponent("pdf-\(item.id).pdf"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            try JSONEncoder().encode(item).write(to: directory.appendingPathComponent("pdf-\(item.id).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("pdf-\(item.id).pdf"))
            throw error
        }
        return item
    }

    func pending(for account: CaptureInbox.Account) -> [Pending] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("pdf-") && $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0), let item = try? JSONDecoder().decode(Pending.self, from: data), item.account == account else { return nil }
            return item
        }
    }

    func remove(_ item: Pending) throws {
        guard let directory else { return }
        for ext in ["json", "pdf"] {
            let url = directory.appendingPathComponent("pdf-\(item.id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func upload(_ item: Pending) async throws {
        guard let credentials = CaptureSessionStore.read(), credentials.account == item.account,
              let directory else { throw CaptureUploader.Failure.signIn }
        let data = try Self.readFile(directory.appendingPathComponent("pdf-\(item.id).pdf"))
        var url = URLComponents(url: item.account.server.appendingPathComponent("documents/file"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "filename", value: item.filename)]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 90
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await CaptureUploader.send(request)
        guard CaptureSessionStore.read() == credentials else { throw CaptureUploader.Failure.changedAccount }
        guard response.statusCode == 202 else {
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            throw Failure.message(object?["detail"] as? String ?? "Could not upload the PDF. It is kept on this device for retry.")
        }
        struct Receipt: Decodable { let document_id: String; let document_status: String }
        _ = try JSONDecoder().decode(Receipt.self, from: body)
        try remove(item)
    }
}
