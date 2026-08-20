import Foundation
import Testing

@testable import Hearful

@Suite("Development authentication")
struct DevelopmentAuthenticationTests {
    private let localURL = URL(string: "http://localhost:8000")!

    @Test func localDebugBuildHasAUsefulDefault() {
        #expect(
            DevelopmentAuthentication.token(baseURL: localURL, environment: [:])
                == "hearful-local-development")
    }

    @Test func anExplicitTokenReplacesTheDefault() {
        let token = DevelopmentAuthentication.token(
            baseURL: localURL,
            environment: ["HEARFUL_DEVELOPMENT_AUTH_TOKEN": "another-local-token"])
        #expect(token == "another-local-token")
    }

    @Test func anEmptyExplicitTokenDisablesTheBypass() {
        let token = DevelopmentAuthentication.token(
            baseURL: localURL,
            environment: ["HEARFUL_DEVELOPMENT_AUTH_TOKEN": "  "])
        #expect(token == nil)
    }

    @Test func aRemoteServerNeverReceivesTheDevelopmentToken() {
        let token = DevelopmentAuthentication.token(
            baseURL: AppConfiguration.productionBaseURL,
            environment: ["HEARFUL_DEVELOPMENT_AUTH_TOKEN": "another-local-token"])
        #expect(token == nil)
    }
}
