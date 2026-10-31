import Foundation
import Testing
@testable import Hearful

private actor PDFTransport: ArticlePDFTransport {
    var request: URLRequest?
    let status: Int
    let mime: String
    let body: String
    init(status: Int = 200, mime: String = "application/pdf", body: String = "%PDF-1.7\nfixture") {
        self.status = status; self.mime = mime; self.body = body
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        self.request = request
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(body.utf8).write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                     headerFields: ["Content-Type": mime])!)
    }
}

private actor DelayedPDF: ArticleExportAPI {
    var continuation: CheckedContinuation<ArticlePDFFile, any Error>?
    func export(episodeID: Int, contentID: Int?, textVersion: String?, title: String) async throws -> ArticlePDFFile {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    var waiting: Bool { continuation != nil }
    func finish(_ file: ArticlePDFFile) { continuation?.resume(returning: file); continuation = nil }
    func fail() { continuation?.resume(throwing: APIError(underlying: "Unavailable")); continuation = nil }
}

@Suite("Article PDF export") @MainActor
struct ArticleExportTests {
    private var episode: Episode {
        Episode(id: 1, title: "Article", description: nil, audioURL: nil, durationSeconds: nil,
                publishedAt: nil, link: nil, positionSeconds: nil, completed: false, hasText: true)
    }

    @Test func downloadsSelectedVersionWithCapturedCredentialsToAFile() async throws {
        let transport = PDFTransport()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = ArticleExportClient(baseURL: URL(string: "https://example.org")!, token: "captured",
                                      transport: transport, directory: directory)
        let file = try await api.export(episodeID: 12, contentID: 34, textVersion: String(repeating: "a", count: 64),
                                        title: "../../科学: A/B")
        #expect(file.url.lastPathComponent == "科学 AB.pdf")
        #expect(try Data(contentsOf: file.url) == Data("%PDF-1.7\nfixture".utf8))
        let request = await transport.request
        #expect(request?.url?.path == "/episodes/12/export.pdf")
        #expect(request?.url?.query?.contains("content_id=34") == true)
        #expect(request?.url?.query?.contains("text_version=" + String(repeating: "a", count: 64)) == true)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer captured")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/pdf")
        #expect(request?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func rejectsWrongMimeAndInvalidPDF() async {
        for transport in [PDFTransport(mime: "text/html"), PDFTransport(body: "not a PDF")] {
            let api = ArticleExportClient(token: "token", transport: transport)
            await #expect(throws: APIError.self) {
                try await api.export(episodeID: 1, contentID: nil, textVersion: nil, title: "Article")
            }
        }
    }

    @Test func serverFailureIsReadableAndRetryable() async {
        let transport = PDFTransport(status: 503, mime: "application/json",
            body: #"{"detail":{"spoken_response":"PDF export is busy. Please try again."}}"#)
        let model = ArticleExportModel()
        await model.prepare(episode: episode, contentID: nil, textVersion: nil,
                            api: ArticleExportClient(token: "token", transport: transport))
        #expect(model.error == "PDF export is busy. Please try again.")
        #expect(model.file == nil && !model.busy)
    }

    @Test(arguments: [false, true]) func lateResponseCannotSurviveClosingOrChangingAccounts(accountChanged: Bool) async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = ArticlePDFFile(url: folder.appendingPathComponent("Article.pdf"))
        try Data("%PDF-1.7".utf8).write(to: file.url)
        let api = DelayedPDF()
        let model = ArticleExportModel()
        var current = true
        let task = Task { await model.prepare(episode: episode, contentID: nil, textVersion: nil,
                                              api: api, validSession: { current }) }
        while !(await api.waiting) { await Task.yield() }
        if accountChanged { current = false } else { model.clear() }
        await api.finish(file)
        await task.value
        #expect(model.file == nil && !model.busy)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func closingWhileCheckingAFailureCannotResurrectAnAlert() async {
        let api = DelayedPDF()
        let model = ArticleExportModel()
        var checks = 0
        let task = Task { await model.prepare(episode: episode, contentID: nil, textVersion: nil, api: api,
            validSession: {
                checks += 1
                if checks == 2 { model.clear() }
                return true
            }) }
        while !(await api.waiting) { await Task.yield() }
        await api.fail()
        await task.value
        #expect(model.error == nil && model.file == nil && !model.busy)
    }
}
