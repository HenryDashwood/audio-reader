import Foundation
import Testing
@testable import Hearful

@MainActor
struct ShareSheetUploadTests {
    private final class Request {
        var calls = 0
        var reply: CheckedContinuation<Void, Error>?

        func send() async throws {
            calls += 1
            try await withCheckedThrowingContinuation { reply = $0 }
        }

        func waitForRequest() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while reply == nil && ContinuousClock.now < deadline { await Task.yield() }
            try #require(reply != nil)
        }
    }

    @Test func reviewedFileAndLinkCannotEnterTheReplacementAccountsQueues() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let links = CaptureInbox(directory: directory)
        let files = PDFUploadInbox(directory: directory)
        let server = URL(string: "https://example.invalid")!
        let first = CaptureInbox.Account(userID: "first", server: server)
        let second = CaptureInbox.Account(userID: "second", server: server)
        let data = Data("%PDF-1.7 fixture".utf8)
        try links.configure(first)
        let reviewed = try #require(links.account)
        try links.configure(second)

        #expect(throws: CaptureUploader.Failure.self) {
            try files.save(data, filename: "First.pdf", reviewedBy: reviewed, captureInbox: links)
        }
        #expect(throws: CaptureUploader.Failure.self) {
            try links.save(url: server, title: "First link", reviewedBy: reviewed)
        }
        for owner in [first, second] {
            #expect(files.pending(for: owner).isEmpty)
            #expect(links.pending(for: owner).isEmpty)
        }

        let newReview = try #require(links.account)
        let pdf = try files.save(data, filename: "Second.pdf", reviewedBy: newReview, captureInbox: links)
        let link = try links.save(url: server, title: "Second link", reviewedBy: newReview)
        #expect(files.pending(for: second).map(\.id) == [pdf.id])
        #expect(links.pending(for: second).map(\.id) == [link.id])
    }

    enum Outcome: CaseIterable { case success, failure, cancellation }

    @Test(arguments: Outcome.allCases)
    func dismissalSuppressesLateFeedback(outcome: Outcome) async throws {
        let sheet = ShareSheetUpload()
        let request = Request()
        var notifications = 0
        sheet.start(upload: request.send) { _ in notifications += 1 }
        try await request.waitForRequest()
        let task = try #require(sheet.task)
        sheet.dismiss()
        #expect(task.isCancelled)
        switch outcome {
        case .success: request.reply?.resume()
        case .failure: request.reply?.resume(throwing: URLError(.badServerResponse))
        case .cancellation: request.reply?.resume(throwing: URLError(.cancelled))
        }
        await task.value
        #expect(notifications == 0)
    }

    @Test func dismissedInAppImportFinishesOneUploadWithoutPresentingItsResult() async throws {
        let sheet = ShareSheetUpload()
        let request = Request()
        var accepted = 0
        var announcements = 0
        func retry() {
            sheet.start(upload: {
                try await request.send()
                accepted += 1
            }, completion: { _ in announcements += 1 })
        }
        retry()
        retry()
        try await request.waitForRequest()
        let task = try #require(sheet.task)
        sheet.dismiss(cancelUpload: false)
        #expect(!task.isCancelled)
        request.reply?.resume()
        await task.value
        #expect(request.calls == 1)
        #expect(accepted == 1)
        #expect(announcements == 0)
    }

    @Test func doubleTapRetryStartsOneMoreRequest() async throws {
        let sheet = ShareSheetUpload()
        let request = Request()
        var messages: [String] = []
        func save() {
            sheet.start(upload: request.send) { result in
                switch result {
                case .success: messages.append("saved")
                case .failure: messages.append("queued")
                }
            }
        }
        save()
        try await request.waitForRequest()
        let first = try #require(sheet.task)
        request.reply?.resume(throwing: URLError(.badServerResponse))
        await first.value
        request.reply = nil
        save()
        save()
        try await request.waitForRequest()
        let retry = try #require(sheet.task)
        request.reply?.resume()
        await retry.value
        #expect(request.calls == 2)
        #expect(messages == ["queued", "saved"])
    }
}
