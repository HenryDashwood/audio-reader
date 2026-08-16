import Foundation
import MetricKit
import OSLog

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "telemetry")

/// Forwards the crash and hang reports iOS collects about this app.
///
/// The alternative is what it replaces: reading `.ips` files off the device by
/// hand over a cable, which needs the phone, a Mac and someone who knows to
/// look. She will not report a crash — from the inside, a crash and the app
/// being closed are the same silence — so if the phone does not say, nobody
/// does.
///
/// iOS delivers these at most once a day, and only when the diagnostics
/// setting is left on, so this answers "what has been crashing" and never
/// "why did that just fail". The wide event next to it covers that.
///
/// Nothing here can fail loudly: a diagnostic that interferes with playing a
/// podcast has its priorities backwards.
@MainActor
final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber {
    private let api: HearfulAPIProtocol

    init(api: HearfulAPIProtocol) {
        self.api = api
        super.init()
        MXMetricManager.shared.add(self)
    }

    /// Crashes, hangs, disk-write and launch problems, as a day's batch.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Deliberately the summary and not the whole payload. A full
        // MetricKit payload is a large JSON document, most of it call stacks
        // that mean nothing without the matching dSYM — worth having on a Mac,
        // not worth uploading from a phone on someone's mobile data.
        let events = payloads.flatMap(Self.summarise)
        guard !events.isEmpty else { return }
        Task { @MainActor in
            for event in events {
                do {
                    try await api.reportDiagnostic(event)
                } catch {
                    log.notice("could not send diagnostic: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated static func summarise(_ payload: MXDiagnosticPayload) -> [[String: any Sendable]] {
        var events: [[String: any Sendable]] = []
        let window = payload.timeStampEnd

        for crash in payload.crashDiagnostics ?? [] {
            var event: [String: any Sendable] = ["kind": "crash"]
            event["signal"] = crash.signal?.intValue
            event["exception_type"] = crash.exceptionType?.intValue
            event["exception_code"] = crash.exceptionCode?.intValue
            event["termination_reason"] = crash.terminationReason
            // The one field that would have named last night's SIGABRT
            // outright, instead of it taking a stack trace to work out.
            event["virtual_memory_region"] = crash.virtualMemoryRegionInfo
            events.append(Self.stamped(event, at: window, from: crash))
        }

        for hang in payload.hangDiagnostics ?? [] {
            events.append(
                Self.stamped(
                    ["kind": "hang", "hang_seconds": hang.hangDuration.value],
                    at: window, from: hang))
        }

        return events
    }

    private nonisolated static func stamped(
        _ event: [String: any Sendable], at end: Date, from diagnostic: MXDiagnostic
    ) -> [String: any Sendable] {
        var event = event
        // Which build it happened on. Without it a crash cannot be tied to the
        // change that caused it, which is most of what a crash report is for —
        // and these arrive a day late, often for a build no longer installed.
        event["app_version"] = diagnostic.applicationVersion
        event["os_version"] = diagnostic.metaData.osVersion
        event["window_end"] = ISO8601DateFormatter().string(from: end)
        return event.compactMapValues { $0 }
    }
}
