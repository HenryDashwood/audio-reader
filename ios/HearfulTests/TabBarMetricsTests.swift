import Combine
import Testing
import UIKit

@testable import Hearful

@Suite("Tab bar measurements")
@MainActor
struct TabBarMetricsTests {
    @Test func repeatedLayoutDoesNotInvalidateTheTabHierarchy() throws {
        let metrics = TabBarMetrics()
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let bar = UITabBar(frame: CGRect(x: 0, y: 700, width: 400, height: 80))
        let platter = UIView(frame: CGRect(x: 20, y: 0, width: 360, height: 60))
        bar.insertSubview(platter, at: 0)
        window.addSubview(bar)

        metrics.measure(from: bar)
        #expect(metrics.pillWidth == 360)
        #expect(metrics.pillTop == 700)

        var publications = 0
        let subscription = metrics.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        for _ in 0..<100 { metrics.measure(from: bar) }
        #expect(publications == 0)

        platter.frame.size.width = 340
        metrics.measure(from: bar)
        #expect(metrics.pillWidth == 340)
        #expect(publications == 1)

        bar.frame.origin.y = 680
        metrics.measure(from: bar)
        #expect(metrics.pillTop == 680)
        #expect(publications == 2)

        bar.removeFromSuperview()
        metrics.measure(from: bar)
        metrics.measure(from: nil)
        #expect(metrics.pillWidth == 340)
        #expect(metrics.pillTop == 680)
        #expect(publications == 2)
    }
}
