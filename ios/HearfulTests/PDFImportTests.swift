import Foundation
import Testing
@testable import Hearful

struct PDFImportTests {
    @Test(arguments: [nil, "", "  "] as [String?])
    func pendingCapturesAlwaysHaveReadableTitles(title: String?) throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = CaptureInbox(directory: directory)
        try inbox.configure(.init(userID: "alice", server: URL(string: "https://example.com")!))
        let capture = try inbox.save(url: URL(string: "https://arxiv.org/pdf/1706.03762")!, title: title, contentFormat: "pdf")
        #expect(capture.displayTitle == "1706.03762")
        #expect(inbox.pending(for: capture.account).first?.displayTitle == "1706.03762")
    }

    @Test func fileQueueSurvivesReopeningAndRemainsBoundToAccount() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = PDFUploadInbox(directory: directory)
        let alice = CaptureInbox.Account(userID: "alice", server: URL(string: "https://example.com")!)
        let bob = CaptureInbox.Account(userID: "bob", server: alice.server)
        let data = Data("%PDF-1.7\nfixture".utf8)
        let saved = try inbox.save(data, filename: "Study.pdf", account: alice)
        let reopened = PDFUploadInbox(directory: directory)
        #expect(reopened.pending(for: alice).map(\.id) == [saved.id])
        #expect(reopened.pending(for: bob).isEmpty)
        #expect(try PDFUploadInbox.readFile(directory.appendingPathComponent("pdf-\(saved.id).pdf")) == data)
        try reopened.remove(saved)
        #expect(reopened.pending(for: alice).isEmpty)
    }
    @Test func invalidFilesAreRejectedAndPendingStatusSurvivesCaching() throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<html>Login</html>".utf8).write(to: url)
        #expect(throws: Error.self) { try PDFUploadInbox.readFile(url) }
        let data = Data(#"{"id":42,"title":"Study","document_id":"abc","document_status":"processing"}"#.utf8)
        let episode = try JSONDecoder().decode(Episode.self, from: data)
        #expect(episode.preparingPDF)
        let cached = try JSONDecoder().decode(Episode.self, from: JSONEncoder().encode(episode))
        #expect(cached.documentID == "abc")
        #expect(cached.preparingPDF)
    }
}
