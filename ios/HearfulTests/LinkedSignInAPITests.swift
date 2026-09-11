import Foundation
import Testing

@testable import Hearful

@Suite("Linked sign-in API contracts")
struct LinkedSignInAPITests {
    private func client(_ transport: FakeTransport) -> HearfulAPI {
        HearfulAPI(baseURL: URL(string: "https://test.local")!, transport: transport)
    }

    @Test func googleLoginUsesTheSharedAccountResponse() async throws {
        let transport = FakeTransport(json: """
            {"token":"session","user":{"id":"same-account","display_name":null,"ai_data_sharing_consented":false}}
            """)
        let result = try await client(transport).login(googleIdentityToken: "google-proof")
        let request = try #require(transport.lastRequest)
        #expect(request.url?.path == "/auth/google")
        #expect(request.httpMethod == "POST")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["identity_token": "google-proof"])
        #expect(result.user.id == "same-account")
        #expect(!result.user.aiDataSharingConsented)
    }

    @Test(arguments: ["apple", "google"])
    func linkingUsesTheAuthenticatedLinkRoute(provider: String) async throws {
        let transport = FakeTransport(json: #"{"providers":["apple","google"]}"#)
        let code = provider == "apple" ? "apple-code" : nil
        let result = try await client(transport).linkIdentity(provider: provider, identityToken: "proof", authorizationCode: code)
        let request = try #require(transport.lastRequest)
        #expect(request.url?.path == "/me/identities/\(provider)")
        #expect(request.httpMethod == "POST")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body["identity_token"] == "proof")
        #expect(body["authorization_code"] == code)
        #expect(result.providers == ["apple", "google"])
    }

    @Test func providerListHasItsOwnRoute() async throws {
        let transport = FakeTransport(json: #"{"providers":["apple"]}"#)
        #expect(try await client(transport).linkedIdentities().providers == ["apple"])
        #expect(transport.lastRequest?.httpMethod == "GET")
        #expect(transport.lastRequest?.url?.path == "/me/identities")
    }

    @Test(arguments: [400, 409, 503])
    func providerFailureDoesNotInvalidateTheMagpieSession(status: Int) async throws {
        let transport = FakeTransport(status: status, json: """
            {"detail":{"spoken_response":"This sign-in could not be connected."}}
            """)
        do {
            _ = try await client(transport).linkIdentity(provider: "google", identityToken: "proof", authorizationCode: nil)
            Issue.record("Expected a provider error")
        } catch let error as APIError {
            #expect(!error.isAuthFailure)
            #expect(error.spokenResponse == "This sign-in could not be connected.")
        }
    }

    @Test func unknownProviderCannotChangeTheRequestPath() async throws {
        let transport = FakeTransport(json: "{}")
        await #expect(throws: APIError.self) {
            try await client(transport).linkIdentity(provider: "../auth/logout", identityToken: "proof", authorizationCode: nil)
        }
        #expect(transport.lastRequest == nil)
    }
}
