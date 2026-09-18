import Combine
import Foundation
import Network
import UIKit

extension Notification.Name {
    nonisolated static let hearfulArticleCached = Notification.Name("hearfulArticleCached")
    nonisolated static let hearfulRetryOffline = Notification.Name("hearfulRetryOffline")
}

nonisolated struct OfflineRetrySchedule {
    private var failures = 0
    private(set) var nextAttempt = Date.distantPast
    mutating func failed() {
        failures = min(failures + 1, 7)
        nextAttempt = Date().addingTimeInterval(min(300, 5 * pow(2, Double(failures - 1))))
    }
    mutating func reset() { failures = 0; nextAttempt = .distantPast }
    var isDue: Bool { Date() >= nextAttempt }
}

/// A connection is a retry hint, not proof that the API is reachable. Consumers
/// retain their local data and coalesce concurrent requests themselves.
@MainActor
final class OfflineRecovery {
    static let shared = OfflineRecovery()
    private let monitor = NWPathMonitor()
    private var subscriptions: Set<AnyCancellable> = []
    private var lastRetry = Date.distantPast
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in OfflineRecovery.shared.retry(resetBackoff: true) }
        }
        monitor.start(queue: DispatchQueue(label: "com.henrydashwood.hearful.connectivity"))
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.retry(resetBackoff: true) } }
            .store(in: &subscriptions)
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.retry() } }
            .store(in: &subscriptions)
    }

    private func retry(resetBackoff: Bool = false) {
        guard ShortcutScope.current != nil, UIApplication.shared.applicationState != .background,
              Date().timeIntervalSince(lastRetry) >= 5 else { return }
        lastRetry = Date()
        NotificationCenter.default.post(name: .hearfulRetryOffline, object: resetBackoff)
    }
}
