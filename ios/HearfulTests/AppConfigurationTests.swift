import Foundation
import Synchronization
import Testing

@testable import Hearful

private func store() -> UserDefaults {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    return defaults
}

private final class ChangeCount: Sendable {
    let value = Mutex(0)
}

@Suite("API base URL")
struct AppConfigurationTests {
    @Test func debugBuildDefaultsToTheLocalBackend() {
        #if DEBUG
            #expect(AppConfiguration.defaultBaseURL.absoluteString == "http://localhost:8000")
        #endif
    }

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

    @Test(arguments: [
        "http://192.168.1.246:8000", AppConfiguration.productionBaseURL.absoluteString,
    ])
    func rereadingTheAddressLeavesTheStoreAlone(override: String) {
        // Settings reads the address from its body. A write on every read
        // invalidated its @AppStorage properties, so the body ran forever.
        let defaults = store()
        let environment = ["HEARFUL_API_URL": override]
        _ = AppConfiguration.resolveBaseURL(environment: environment, defaults: defaults)

        let changes = ChangeCount()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in changes.value.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        for _ in 0..<3 {
            _ = AppConfiguration.resolveBaseURL(environment: environment, defaults: defaults)
        }
        #expect(changes.value.withLock { $0 } == 0)
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
                "HEARFUL_API_URL": AppConfiguration.productionBaseURL.absoluteString
            ],
            defaults: defaults)

        #expect(url == AppConfiguration.productionBaseURL)
        #expect(AppConfiguration.rememberedOverride(defaults: defaults) == nil)
    }
}
