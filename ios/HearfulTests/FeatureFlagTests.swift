import Foundation
import Testing

@testable import Hearful

@Suite("Account feature flags")
struct FeatureFlagTests {
    @Test func olderServersAndUnknownFlagsAreDisabled() throws {
        let user = try JSONDecoder().decode(UserInfo.self, from: Data(#"{"id":"one","display_name":null}"#.utf8))
        #expect(user.featureFlags.isEmpty)
        #expect(!user.isFeatureEnabled("experiment"))
    }

    @Test func explicitDenialsArePreserved() throws {
        let data = Data(#"{"id":"one","feature_flags":{"experiment":true,"pdf_unlimited":false}}"#.utf8)
        let user = try JSONDecoder().decode(UserInfo.self, from: data)
        #expect(user.isFeatureEnabled("experiment"))
        #expect(!user.isFeatureEnabled("pdf_unlimited"))
        #expect(!user.isFeatureEnabled("unknown"))
    }

    @Test func meLoadsFlagsThroughTheExistingAccountRequest() async throws {
        let transport = FakeTransport(json: #"{"id":"one","feature_flags":{"experiment":true}}"#)
        let api = HearfulAPI(baseURL: URL(string: "https://test.local")!, transport: transport)
        let user = try await api.me()
        #expect(user.isFeatureEnabled("experiment"))
        #expect(transport.lastRequest?.url?.path == "/me")
    }
}
