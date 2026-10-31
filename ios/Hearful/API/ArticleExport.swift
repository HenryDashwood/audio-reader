import Foundation

nonisolated struct ArticlePDFFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
}

nonisolated protocol ArticleExportAPI: Sendable {
    func export(episodeID: Int, contentID: Int?, textVersion: String?, title: String) async throws -> ArticlePDFFile
}

nonisolated protocol ArticlePDFTransport: Sendable {
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

nonisolated struct NativeArticlePDFTransport: ArticlePDFTransport {
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: ArticlePDFDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.download(for: request)
    }
}

/// Immutable delegate: callbacks neither share nor mutate application state.
private nonisolated final class ArticlePDFDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The account token belongs to this endpoint, never a redirected URL.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > ArticleExportClient.maxBytes || totalBytesExpectedToWrite > ArticleExportClient.maxBytes {
            downloadTask.cancel()
        }
    }
}

nonisolated struct ArticleExportClient: ArticleExportAPI {
    static let maxBytes: Int64 = 32 * 1024 * 1024
    let baseURL: URL
    let token: String?
    let transport: any ArticlePDFTransport
    let directory: URL

    init(baseURL: URL = AppConfiguration.apiBaseURL, token: String?,
         transport: any ArticlePDFTransport = NativeArticlePDFTransport(),
         directory: URL = URL.cachesDirectory.appending(path: "ArticleExports", directoryHint: .isDirectory)) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
        self.directory = directory
    }

    @concurrent func export(episodeID: Int, contentID: Int?, textVersion: String?, title: String) async throws -> ArticlePDFFile {
        guard episodeID > 0, contentID == nil || contentID! > 0,
              textVersion == nil || isProgressToken(textVersion!) else {
            throw APIError(underlying: "Invalid article export selection")
        }
        var components = URLComponents(url: baseURL.appendingPathComponent("episodes/\(episodeID)/export.pdf"),
                                       resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = []
        if let contentID { query.append(URLQueryItem(name: "content_id", value: "\(contentID)")) }
        if let textVersion { query.append(URLQueryItem(name: "text_version", value: textVersion)) }
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (temporary, response) = try await transport.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw APIError(underlying: "PDF export response") }
        if !(200..<300).contains(http.statusCode) {
            let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let data = size <= 65_536 ? (try? Data(contentsOf: temporary)) : nil
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let detail = object?["detail"] as? [String: Any]
            throw APIError(spokenResponse: detail?["spoken_response"] as? String
                ?? (http.statusCode == 404 ? "PDF export is unavailable for this article on this server."
                    : "The PDF couldn’t be prepared. Please try again."),
                underlying: "PDF export HTTP \(http.statusCode)", isAuthFailure: http.statusCode == 401,
                statusCode: http.statusCode)
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        guard http.mimeType?.lowercased() == "application/pdf", size > 5, size <= Self.maxBytes,
              try handle.read(upToCount: 5) == Data("%PDF-".utf8) else {
            throw APIError(spokenResponse: "The server didn’t return a readable PDF. Please try again.",
                           underlying: "Invalid PDF export")
        }
        try Task.checkCancellation()
        Self.prune(directory)
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(Self.filename(title))
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return ArticlePDFFile(url: destination)
    }

    static func filename(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: " .-_"))
        let stem = String(String.UnicodeScalarView(title.unicodeScalars.filter { allowed.contains($0) })).prefix(100)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return (stem.isEmpty ? "Article" : stem) + ".pdf"
    }

    private static func prune(_ directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files {
            if let date = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
               date < Date().addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: file) }
        }
    }

    @concurrent static func discard(_ file: ArticlePDFFile) async {
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }
}
