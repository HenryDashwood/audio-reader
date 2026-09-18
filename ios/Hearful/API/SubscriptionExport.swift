import Foundation

nonisolated protocol SubscriptionExportAPI: Sendable {
    func export() async throws -> Data
}

nonisolated struct SubscriptionExportClient: SubscriptionExportAPI {
    let baseURL: URL
    let token: String?
    let transport: any DataTransport

    init(baseURL: URL = AppConfiguration.apiBaseURL, token: String? = KeychainTokenStore.token,
         transport: any DataTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    func export() async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("feeds/export"))
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/x-opml", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(underlying: "export response") }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = object?["detail"] as? [String: Any]
            throw APIError(spokenResponse: detail?["spoken_response"] as? String
                ?? "Subscriptions couldn’t be exported. Please try again.", underlying: "export HTTP \(http.statusCode)",
                isAuthFailure: http.statusCode == 401, statusCode: http.statusCode)
        }
        return data
    }
}
