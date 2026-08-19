import Foundation
import Testing

@testable import Hearful

private func store() -> UserDefaults {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    return defaults
}

@Suite("API base URL")
struct AppConfigurationTests {
    @Test func usesTheEnvironmentOverrideWhenGiven() {
        let url = AppConfiguration.resolveBaseURL(
            environment: ["HEARFUL_API_URL": "http://192.168.1.246:8000"], defaults: store())
        #expect(url.absoluteString == "http://192.168.1.246:8000")
    }

    @Test func remembersTheOverrideForLaterLaunches() {
        // Launching from Xcode passes the address; tapping the icon does not.
        // Forgetting it between launches makes the app look broken.
        let defaults = store()
        _ = AppConfiguration.resolveBaseURL(
            environment: ["HEARFUL_API_URL": "http://192.168.1.246:8000"], defaults: defaults)

        let next = AppConfiguration.resolveBaseURL(environment: [:], defaults: defaults)
        #expect(next.absoluteString == "http://192.168.1.246:8000")
    }

    @Test func fallsBackToTheDefaultWhenNothingIsKnown() {
        let url = AppConfiguration.resolveBaseURL(environment: [:], defaults: store())
        #expect(url == AppConfiguration.defaultBaseURL)
    }

    @Test func aLaterOverrideReplacesTheRememberedOne() {
        let defaults = store()
        _ = AppConfiguration.resolveBaseURL(
            environment: ["HEARFUL_API_URL": "http://10.0.0.1:8000"], defaults: defaults)
        let next = AppConfiguration.resolveBaseURL(
            environment: ["HEARFUL_API_URL": "http://192.168.1.246:8000"], defaults: defaults)

        #expect(next.absoluteString == "http://192.168.1.246:8000")
    }

    @Test func ignoresAnUnparsableOverride() {
        let url = AppConfiguration.resolveBaseURL(
            environment: ["HEARFUL_API_URL": ""], defaults: store())
        #expect(url == AppConfiguration.defaultBaseURL)
    }

    @Test func productionAddressClearsAStaleDevelopmentOverride() {
        let defaults = store()
        _ = AppConfiguration.resolveBaseURL(
            environment: ["HEARFUL_API_URL": "http://192.168.1.246:8000"],
            defaults: defaults)

        let url = AppConfiguration.resolveBaseURL(
            environment: [
                "HEARFUL_API_URL": AppConfiguration.defaultBaseURL.absoluteString
            ],
            defaults: defaults)

        #expect(url == AppConfiguration.defaultBaseURL)
        #expect(AppConfiguration.rememberedOverride(defaults: defaults) == nil)
    }
}
