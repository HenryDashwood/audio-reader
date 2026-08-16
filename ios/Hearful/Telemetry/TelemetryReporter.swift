import Foundation
import OSLog

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "telemetry")

@MainActor
protocol TelemetryReporting {
    func report(_ attempt: VoiceAttempt)
}

/// Sends wide events to the backend, and keeps the ones it could not send.
///
/// Queued to disk rather than dropped, because the events most worth having
/// are the ones least likely to get through: a spoken request that failed and
/// a request that could not be sent have a common cause more often than not.
/// The queue is flushed on the next attempt, so a failure during an outage
/// still arrives — late, with its own timing intact.
///
/// Nothing here is allowed to affect what she can do. Every failure is
/// swallowed: telemetry that costs a listener her podcast is worse than no
/// telemetry.
@MainActor
final class TelemetryReporter: TelemetryReporting {
    private let api: HearfulAPIProtocol
    private let store: URL?
    /// Small on purpose. This is a record of recent behaviour, not an archive,
    /// and an unbounded queue on a phone that has been offline for a week is a
    /// liability rather than an asset.
    private let queueLimit = 50

    init(api: HearfulAPIProtocol, store: URL? = TelemetryReporter.defaultStore()) {
        self.api = api
        self.store = store
    }

    func report(_ attempt: VoiceAttempt) {
        // The trace context travels *with* the event rather than beside it: a
        // queued event sent tomorrow still belongs to the request it described,
        // and would otherwise arrive orphaned from it.
        let queued: [String: any Sendable] = [
            "traceparent": attempt.traceparent(),
            "event": attempt.payload(),
        ]
        Task { await self.send(queued) }
    }

    private func send(_ payload: [String: any Sendable]) async {
        var pending = queued()
        pending.append(payload)
        var undelivered: [[String: any Sendable]] = []
        for entry in pending {
            guard let event = entry["event"] as? [String: any Sendable] else { continue }
            do {
                try await api.reportVoiceAttempt(event, traceparent: entry["traceparent"] as? String)
            } catch {
                // Keep it for next time rather than retrying now: she may be
                // mid-request, and this must never be the slow thing.
                log.notice("could not send voice attempt: \(error.localizedDescription)")
                undelivered.append(entry)
            }
        }
        save(Array(undelivered.suffix(queueLimit)))
    }

    // MARK: - The queue

    static func defaultStore() -> URL? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return directory?.appendingPathComponent("voice-attempts.json")
    }

    private func queued() -> [[String: any Sendable]] {
        guard let store, let data = try? Data(contentsOf: store) else { return [] }
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: any Sendable]]
        return parsed ?? []
    }

    private func save(_ events: [[String: any Sendable]]) {
        guard let store else { return }
        guard !events.isEmpty else {
            try? FileManager.default.removeItem(at: store)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: events) else { return }
        try? data.write(to: store, options: .atomic)
    }
}
