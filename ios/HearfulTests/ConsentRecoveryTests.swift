import Combine
import Foundation
import Testing
@testable import Hearful

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ConsentRecoveryTests {
    private actor Transport: DataTransport {
        var heldPath: String?
        private var reply: CheckedContinuation<Void, Never>?
        let arrival = AsyncStream<Void>.makeStream()
        var user = "first"
        private(set) var consentWrites: [String] = []
        private(set) var deletions: [String] = []
        private(set) var logouts: [String] = []
        var granted = true
        var heldStatus = 200

        func hold(_ path: String, status: Int = 200) { heldPath = path; heldStatus = status }
        func switchUser() { user = "second"; granted = false }
        func release() { reply?.resume(); reply = nil }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            if url.path == "/auth/logout" { logouts.append(request.value(forHTTPHeaderField: "Authorization") ?? "") }
            if request.httpMethod == "DELETE" { deletions.append(request.value(forHTTPHeaderField: "Authorization") ?? "") }
            if url.path == "/me/ai-data-sharing" {
                let json = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Bool])
                guard let value = json["granted"] else { throw URLError(.badURL) }
                consentWrites.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                granted = value
            }
            let data = try JSONSerialization.data(withJSONObject: ["id": user, "ai_data_sharing_consented": granted])
            var status = 200
            if heldPath == url.path {
                status = heldStatus
                heldPath = nil
                await withCheckedContinuation {
                    reply = $0
                    arrival.continuation.yield(())
                    arrival.continuation.finish()
                }
            }
            return (data, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(arguments: [false, true])
    func lateRepliesCannotRestoreAnOldSharingChoice(changeAccount: Bool) async throws {
        var token = "first-token"
        let transport = Transport()
        let api = HearfulAPI(baseURL: URL(string: "https://consent.invalid")!, transport: transport)
        let auth = AuthController(api: api, notificationCenter: NotificationCenter(),
                                  readToken: { token }, writeToken: { _ in })
        auth.bootstrap()
        for await user in auth.$user.values where user != nil { break }
        try #require(auth.user?.aiDataSharingConsented == true)
        await transport.hold(changeAccount ? "/me/ai-data-sharing" : "/me")
        let owner = try #require(auth.sessionOwner)
        let old = Task {
            if changeAccount { try await auth.setAIDataSharing(granted: true, confirmedFor: owner) }
            else { await auth.refreshUser() }
        }
        for await _ in transport.arrival.stream { break }
        if changeAccount {
            token = "second-token"
            await transport.switchUser()
            await auth.refreshUser()
        } else {
            try await auth.setAIDataSharing(granted: false, confirmedFor: owner)
        }
        await transport.release()
        let outcome = await old.result
        if changeAccount {
            #expect(auth.user?.id == "second")
            if case .success = outcome { Issue.record("The old consent request reported success to its caller") }
        }
        #expect(auth.user?.aiDataSharingConsented == false)
    }
    @Test(arguments: [true, false], [200, 503])
    func accountExitReplyCannotRemoveTheReplacementSession(delete: Bool, status: Int) async throws {
        var token: String? = "first-token"
        let transport = Transport()
        let auth = AuthController(api: HearfulAPI(baseURL: URL(string: "https://exit.invalid")!, transport: transport),
                                  notificationCenter: NotificationCenter(), readToken: { token }, writeToken: { token = $0 })
        auth.bootstrap()
        for await user in auth.$user.values where user != nil { break }
        try #require(auth.user?.id == "first")
        await transport.hold(delete ? "/me" : "/auth/logout", status: status)
        let owner = try #require(auth.sessionOwner)
        let exit = Task {
            if delete { try await auth.deleteAccount(confirmedFor: owner) } else { await auth.signOut(for: owner) }
        }
        for await _ in transport.arrival.stream { break }
        token = "second-token"
        await transport.switchUser()
        await auth.refreshUser()
        await transport.release()
        let outcome = await exit.result
        if delete {
            switch outcome {
            case .failure(is CancellationError): break
            default: Issue.record("The old deletion delivered a result to the new session")
            }
        }
        #expect(token == "second-token")
        #expect(auth.state == .signedIn)
        #expect(auth.user?.id == "second")
    }

    @Test(arguments: [false, true])
    func privacyConfirmationBelongsToTheAccountThatOpenedIt(granted: Bool) async throws {
        var token: String? = "first-token"
        let transport = Transport()
        let api = HearfulAPI(baseURL: URL(string: "https://privacy.invalid")!, transport: transport)
        let auth = AuthController(api: api, notificationCenter: NotificationCenter(),
                                  readToken: { token }, writeToken: { token = $0 })
        auth.bootstrap()
        for await user in auth.$user.values where user != nil { break }
        let original = try #require(auth.sessionOwner)
        token = "second-token"
        await transport.switchUser()
        await auth.refreshUser()
        await #expect(throws: CancellationError.self) {
            try await auth.setAIDataSharing(granted: granted, confirmedFor: original)
        }
        #expect(await transport.consentWrites.isEmpty)
        let replacement = try #require(auth.sessionOwner)
        try await auth.setAIDataSharing(granted: granted, confirmedFor: replacement)
        #expect(await transport.consentWrites == ["Bearer second-token"])
        #expect(auth.user?.aiDataSharingConsented == granted)
    }

    @Test(arguments: [false, true])
    func exitControlBelongsToTheAccountThatOpenedIt(delete: Bool) async throws {
        var token: String? = "first-token"
        let transport = Transport()
        let api = HearfulAPI(baseURL: URL(string: "https://exit.invalid")!, transport: transport)
        let auth = AuthController(api: api, notificationCenter: NotificationCenter(),
                                  readToken: { token }, writeToken: { token = $0 })
        auth.bootstrap()
        for await user in auth.$user.values where user != nil { break }
        let original = try #require(auth.sessionOwner)
        token = "second-token"
        await transport.switchUser()
        await auth.refreshUser()
        if delete {
            await #expect(throws: CancellationError.self) { try await auth.deleteAccount(confirmedFor: original) }
        } else {
            await auth.signOut(for: original)
        }
        #expect(await transport.deletions.isEmpty)
        #expect(await transport.logouts.isEmpty)
        #expect(token == "second-token")
        let replacement = try #require(auth.sessionOwner)
        if delete { try await auth.deleteAccount(confirmedFor: replacement) }
        else { await auth.signOut(for: replacement) }
        #expect(await transport.deletions == (delete ? ["Bearer second-token"] : []))
        #expect(await transport.logouts == (delete ? [] : ["Bearer second-token"]))
        #expect(token == nil)
    }

    @Test func unauthorizedReplyBelongsOnlyToItsOriginalServerAndCredential() throws {
        let server = URL(string: "https://magpie.invalid/api")!
        var original = URLRequest(url: server.appendingPathComponent("command/stream"))
        #expect(RejectedSession(original) == nil)
        original.setValue("Bearer first-token", forHTTPHeaderField: "Authorization")
        let rejection = try #require(RejectedSession(original))
        #expect(rejection.matches(token: "first-token", server: server))
        #expect(!rejection.matches(token: nil, server: server))
        #expect(!rejection.matches(token: "second-token", server: server))
        #expect(!rejection.matches(token: "first-token", server: URL(string: "https://other.invalid/api")!))
        #expect(!rejection.matches(token: "first-token", server: URL(string: "https://magpie.invalid/ap")!))
    }

    @Test func oldUnauthorizedResponseFromTheAPILeavesTheNewUserSignedIn() async throws {
        let transport = Transport()
        var token: String? = "rejected-test-token"
        let auth = AuthController(api: HearfulAPI(transport: transport),
                                  readToken: { token }, writeToken: { token = $0 })
        auth.bootstrap()
        for await user in auth.$user.values where user != nil { break }
        try #require(auth.user?.id == "first")
        await transport.hold("/me", status: 401)
        let old = Task {
            await HearfulAPI.$tokenProvider.withValue({ "rejected-test-token" }) { await auth.refreshUser() }
        }
        for await _ in transport.arrival.stream { break }
        token = "replacement-test-token"
        await transport.switchUser()
        await auth.refreshUser()
        await transport.release()
        await old.value
        #expect(token == "replacement-test-token")
        #expect(auth.state == .signedIn)
        #expect(auth.user?.id == "second")
    }

}
