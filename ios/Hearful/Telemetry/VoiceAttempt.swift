import Foundation
import UIKit

/// One spoken request, as the phone experienced it.
///
/// The client half of the wide event on the server. One row per attempt,
/// flat and answerable without a join — the same shape the backend uses for
/// `command`, and for the same reason: a spoken request should be one thing
/// you can query, not a trail of log lines to reassemble afterwards.
///
/// It exists because the failures worth finding happen *before* the backend
/// hears anything. A microphone that never woke, a recogniser that produced
/// nothing, a transport word answered on the phone — none of those make a
/// request, so in the server's telemetry they are an absence, and an absence
/// is not something you can group by.
///
/// Accumulated as it goes and sent once at the end, so an attempt that dies
/// halfway still describes itself. Half-finished attempts are the interesting
/// ones.
@MainActor
final class VoiceAttempt {
    /// The attempt in progress, so the speech layer can describe itself
    /// without every function being handed one. Mirrors `telemetry.annotate`
    /// on the server, and is nil outside an attempt — which is most of the
    /// test suite.
    static var current: VoiceAttempt?

    /// How it ended, in her terms. The one field to group by.
    var outcome: Outcome = .abandoned
    var commandSent = false

    var recogniser: String?
    var usedFallback = false
    /// Milliseconds from starting capture to the first audio buffer.
    ///
    /// The measurement that matters most, because it is the one that was
    /// missing: null means the microphone never came up at all, which for a
    /// long time was indistinguishable from her saying nothing.
    var audioFirstBufferMs: Int?
    var listenSeconds: Double?
    var transcriptEmpty: Bool?
    /// Whether the recogniser had committed to its transcript, or was still
    /// revising when the turn ended.
    var settledAtEnd: Bool?

    /// Answered on the phone, so the server never learns they happened.
    var transportCommand: String?
    var sleepCommand: String?

    var error: String?

    /// W3C trace id, one per spoken request and shared by every call it
    /// makes. What turns two rows in two services into one story: the
    /// command and the event that describes it land in the same trace
    /// without anything having to be joined by timestamp afterwards.
    let traceID = VoiceAttempt.randomHex(bytes: 16)

    private let started = ContinuousClock.now
    private let voiceOver = UIAccessibility.isVoiceOverRunning
    private let firstSinceLaunch: Bool

    /// The first attempt after launch behaves differently from every one
    /// after it — that was the whole shape of the microphone bug — so it has
    /// to be separable in a query rather than inferred from timestamps.
    private static var hasAttempted = false

    init() {
        firstSinceLaunch = !Self.hasAttempted
        Self.hasAttempted = true
    }

    /// Coarse on purpose. The phone collapses every action it cannot carry
    /// out into one — a subscription confirmed and a question asked look
    /// identical from here — so this says only what the phone actually knew.
    /// The server's own event names the action precisely, which is the point
    /// of one wide event *per service* rather than one shared between them.
    enum Outcome: String {
        case played
        /// The backend answered, and all the app did was say the sentence.
        case spoken
        case transport
        case sleep
        case speed
        /// An episode marked played, put aside, or put back.
        case filed
        /// She spoke and nothing was transcribed.
        case noSpeech = "no_speech"
        case permissionDenied = "permission_denied"
        case error
        /// Ended without reaching any of the above — a cancel, or a crash on
        /// the way. Never sent deliberately; it is the default so that a row
        /// which stops early still says so.
        case abandoned
    }

    /// A `traceparent` header for one outgoing request.
    ///
    /// A fresh parent id each time, because the phone emits no spans of its
    /// own for these to be children of — the id is synthetic and only the
    /// trace id is load-bearing. Sampled flag set: there is one user, and
    /// every request she makes is worth keeping.
    func traceparent() -> String {
        "00-\(traceID)-\(Self.randomHex(bytes: 8))-01"
    }

    static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    func payload() -> [String: any Sendable] {
        var fields: [String: any Sendable] = [
            "outcome": outcome.rawValue,
            "command_sent": commandSent,
            "used_fallback": usedFallback,
            "voiceover": voiceOver,
            "first_since_launch": firstSinceLaunch,
            "total_seconds": seconds(since: started),
        ]
        fields["recogniser"] = recogniser
        fields["audio_first_buffer_ms"] = audioFirstBufferMs
        fields["listen_seconds"] = listenSeconds
        fields["transcript_empty"] = transcriptEmpty
        fields["settled_at_end"] = settledAtEnd
        fields["transport_command"] = transportCommand
        fields["sleep_command"] = sleepCommand
        fields["error"] = error
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            fields["app_version"] = version
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            fields["app_build"] = build
        }
        return fields
    }

    private func seconds(since instant: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - instant
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}
