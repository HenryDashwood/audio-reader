import Foundation

/// An extension-safe client for the existing save contract. No app lifecycle or
/// playback dependencies; a capture remains durable until the server confirms its save.
nonisolated struct CaptureUploader: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let transport: Transport
    let session: @Sendable () -> CaptureSessionStore.Session?

    init(transport: @escaping Transport = Self.send,
         session: @escaping @Sendable () -> CaptureSessionStore.Session? = { CaptureSessionStore.read() }) {
        self.transport = transport
        self.session = session
    }

    enum Failure: LocalizedError {
        case signIn, changedAccount, response, preparation(String)
        var errorDescription: String? {
            switch self {
            case .signIn: "Open Magpie once to connect its sign-in to the share pane, then retry. Your capture is kept on this device."
            case .changedAccount: "The signed-in account changed. This capture has not been sent to the new account."
            case .response: "Magpie could not confirm that the article is ready. Your capture is kept on this device. Try again."
            case .preparation(let message): message
            }
        }
    }

    @discardableResult
    func finish(_ capture: CaptureInbox.Capture, inbox: CaptureInbox) async throws -> Bool {
        let preparing = try await upload(capture)
        try Task.checkCancellation()
        do { try inbox.remove(capture) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        return preparing
    }

    @discardableResult
    func upload(_ capture: CaptureInbox.Capture) async throws -> Bool {
        guard let credentials = session(), credentials.account == capture.account else { throw Failure.signIn }
        func checkSession() throws {
            try Task.checkCancellation()
            guard session() == credentials else { throw Failure.changedAccount }
        }
        func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
            try checkSession()
            var request = URLRequest(url: capture.account.server.appendingPathComponent(path))
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 30
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let result = try await transport(request)
            try checkSession()
            return result
        }
        struct Body: Encodable {
            let url: URL
            let title: String?
            let html: String?
            let saved_at: Date
            let content_format: String?
        }
        struct Article: Decodable { let id: Int; let content_id: Int?; let capture_error: String?; let document_id: String?; let document_status: String? }
        struct Problem: Decodable { let detail: String }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(Body(url: capture.url, title: capture.title, html: capture.html,
            saved_at: capture.createdAt, content_format: capture.contentFormat))
        var (data, response) = try await request(capture.replaceExisting == true ? "saved/replace" : "saved", method: "POST", body: body)
        if capture.replaceExisting == true && response.statusCode == 404,
           (try? JSONDecoder().decode(Problem.self, from: data).detail) == "Save this article before replacing its text." {
            (data, response) = try await request("saved", method: "POST", body: body)
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw Failure.signIn }
            let problem = try? JSONDecoder().decode(Problem.self, from: data)
            throw Failure.preparation(problem?.detail ?? "Could not save this item. Please retry.")
        }
        let article = try JSONDecoder().decode(Article.self, from: data)
        if let documentID = article.document_id {
            guard article.id > 0, !documentID.isEmpty,
                  let status = article.document_status,
                  ["queued", "submitting", "processing", "ready", "failed"].contains(status) else { throw Failure.response }
            if status == "failed" { throw Failure.preparation(article.capture_error ?? "PDF preparation failed. Retry from Saved.") }
            return status != "ready"
        }
        if let error = article.capture_error, !error.isEmpty { throw Failure.preparation(error) }
        guard article.id > 0, let contentID = article.content_id, contentID > 0 else { throw Failure.response }
        // The save receipt confirms durable prepared content. Downloading it
        // here would discard the bytes and could turn a successful save into
        // a false failure. The app downloads its own offline copy separately.
        return false
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 45
        let client = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.response }
        return (data, http)
    }
}
