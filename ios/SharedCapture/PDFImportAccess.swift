import Foundation

nonisolated struct PDFCapability: Decodable, Sendable {
    let enabled: Bool
    let consented: Bool
    var subscription_available: Bool? = nil
}

/// Account-bound capability checks shared by the app and share extension.
nonisolated struct PDFImportAccess: Sendable {
    var transport: CaptureUploader.Transport = CaptureUploader.send
    var session: @Sendable () -> CaptureSessionStore.Session? = { CaptureSessionStore.read() }

    func request(for account: CaptureInbox.Account) async throws -> PDFCapability {
        guard let credentials = session(), credentials.account == account else { throw CaptureUploader.Failure.signIn }
        try Task.checkCancellation()
        var request = URLRequest(url: account.server.appendingPathComponent("documents/capability"))
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard session() == credentials else { throw CaptureUploader.Failure.changedAccount }
        guard response.statusCode == 200 else {
            struct Problem: Decodable { let detail: String }
            let message = (try? JSONDecoder().decode(Problem.self, from: data))?.detail
            throw PDFUploadInbox.Failure.message(message ?? "PDF importing is unavailable. Please retry.")
        }
        let capability = try JSONDecoder().decode(PDFCapability.self, from: data)
        return capability
    }
}
