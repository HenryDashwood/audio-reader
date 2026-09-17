import Foundation

nonisolated struct SubscriptionImportItem: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let host: String
    let status: String
    let message: String?
    let selected: Bool
    let retryable: Bool
    let feedID: Int?
    enum CodingKeys: String, CodingKey {
        case id, title, host, status, message, selected, retryable
        case feedID = "feed_id"
    }
}

nonisolated struct SubscriptionImportJob: Decodable, Identifiable, Sendable {
    let id: String
    let status: String
    let duplicates: Int
    let folders: Bool
    let total: Int
    let finished: Int
    let added: Int
    let alreadyFollowing: Int
    let failed: Int
    let notImported: Int
    let items: [SubscriptionImportItem]
    var active: Bool { ["queued", "running"].contains(status) }
    var draft: Bool { status == "draft" }
    enum CodingKeys: String, CodingKey {
        case id, status, duplicates, folders, total, finished, added, failed, items
        case alreadyFollowing = "already_following"
        case notImported = "not_imported"
    }
}

nonisolated protocol SubscriptionImportAPI: Sendable {
    func current() async throws -> SubscriptionImportJob?
    func preview(_ data: Data) async throws -> SubscriptionImportJob
    func start(id: String, entries: [Int], requestID: String) async throws -> SubscriptionImportJob
    func stop(id: String) async throws -> SubscriptionImportJob
    func retry(id: String, requestID: String) async throws -> SubscriptionImportJob
}

/// A fixed server and credential for the lifetime of one screen. Late requests
/// cannot send an old account's chosen file under a newly signed-in credential.
nonisolated struct SubscriptionImportClient: SubscriptionImportAPI {
    let baseURL: URL
    let token: String?
    let transport: any DataTransport

    init(baseURL: URL = AppConfiguration.apiBaseURL, token: String? = KeychainTokenStore.token,
         transport: any DataTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    func current() async throws -> SubscriptionImportJob? {
        try await request("current", method: "GET")
    }
    func preview(_ data: Data) async throws -> SubscriptionImportJob {
        guard data.count <= 5 * 1024 * 1024 else { throw APIError(spokenResponse: "Choose an OPML file smaller than 5 MiB.", underlying: "import size") }
        return try await request("preview", raw: data)
    }
    func start(id: String, entries: [Int], requestID: String) async throws -> SubscriptionImportJob {
        try await request("\(id)/start", body: ["entry_ids": entries, "request_id": requestID, "public_feeds_confirmed": true])
    }
    func stop(id: String) async throws -> SubscriptionImportJob { try await request("\(id)/stop") }
    func retry(id: String, requestID: String) async throws -> SubscriptionImportJob {
        try await request("\(id)/retry", body: ["request_id": requestID])
    }
    private func request<T: Decodable>(_ path: String, method: String = "POST",
                                      body: [String: any Sendable]? = nil, raw: Data? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent("subscription-imports/\(path)"))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(raw == nil ? "application/json" : "application/xml", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try raw ?? body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(underlying: "import response") }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = object?["detail"] as? [String: Any]
            let message = detail?["spoken_response"] as? String
                ?? (http.statusCode == 404 ? "Subscription import isn't available on this server yet, or this import has expired." : "The import could not be updated. Please try again.")
            throw APIError(spokenResponse: message, underlying: "import HTTP \(http.statusCode)",
                           isAuthFailure: http.statusCode == 401, statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
