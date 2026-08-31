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

    @Test(arguments: ["10.0.0.2", "172.16.1.2", "172.31.255.254", "192.168.1.2"])
    func privateLANAddressesCanUseTheDevelopmentToken(host: String) {
        let token = DevelopmentAuthentication.token(
            baseURL: URL(string: "http://\(host):8000")!, environment: [:])

        #expect(token == "hearful-local-development")
    }

    @Test(arguments: ["172.15.1.2", "172.32.1.2", "192.0.2.1"])
    func publicAddressesNeverReceiveTheDevelopmentToken(host: String) {
        let token = DevelopmentAuthentication.token(
            baseURL: URL(string: "http://\(host):8000")!, environment: [:])

        #expect(token == nil)
    }
}
