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
