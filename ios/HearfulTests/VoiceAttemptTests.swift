import Foundation
import Testing

@testable import Hearful

@Suite("Voice attempt event")
@MainActor
struct VoiceAttemptTests {
    @Test func alwaysSaysHowItEnded() {
        // The one field worth grouping by, so it can never be absent — even
        // for an attempt that stopped before reaching any known ending.
        let payload = VoiceAttempt().payload()
        #expect(payload["outcome"] as? String == "abandoned")
    }

    @Test func onlyReportsWhatThePhoneActuallyKnew() {
        // An absent field and a false one mean different things. A microphone
        // that never delivered has no first-buffer time, and recording that as
        // zero would make it indistinguishable from an instant one.
        let payload = VoiceAttempt().payload()
        #expect(payload["audio_first_buffer_ms"] == nil)
        #expect(payload["listen_seconds"] == nil)
        #expect(payload["error"] == nil)
    }

    @Test func carriesTheMeasurementThatWasMissing() {
        let attempt = VoiceAttempt()
        attempt.audioFirstBufferMs = 240
        attempt.recogniser = "analyzer"
        attempt.listenSeconds = 3.1
        let payload = attempt.payload()

        #expect(payload["audio_first_buffer_ms"] as? Int == 240)
        #expect(payload["recogniser"] as? String == "analyzer")
    }

    @Test func onlyOneAttemptPerLaunchIsTheFirst() {
        // The first request after launch failed and the retry worked, every
        // time. Telling them apart has to be a column, not an inference from
        // timestamps — and the flag has to be exclusive, or it says nothing.
        _ = VoiceAttempt()
        let next = VoiceAttempt().payload()["first_since_launch"] as? Bool

        // True whatever ran before in this process, which is what makes it a
        // real assertion rather than one that depends on test ordering.
        #expect(next == false)
    }

    @Test func recordsContextThatTurnedOutToMatter() {
        let payload = VoiceAttempt().payload()
        #expect(payload["voiceover"] is Bool)
        #expect(payload["total_seconds"] is Double)
        #expect(payload["command_sent"] as? Bool == false)
    }

    @Test func isEncodableAsSentToTheBackend() throws {
        // It travels as JSON, so anything unencodable is a silent loss of the
        // whole event rather than of one field.
        let attempt = VoiceAttempt()
        attempt.outcome = .played
        attempt.audioFirstBufferMs = 180
        attempt.transportCommand = nil
        #expect(JSONSerialization.isValidJSONObject(attempt.payload()))
        _ = try JSONSerialization.data(withJSONObject: attempt.payload())
    }

    @Test func namesThePhoneOnlyCommandsTheServerNeverSees() {
        // Transport and sleep words are answered on the phone, so without this
        // the busiest things she says leave no record anywhere.
        let attempt = VoiceAttempt()
        attempt.outcome = .transport
        attempt.transportCommand = "pause"
        let payload = attempt.payload()

        #expect(payload["outcome"] as? String == "transport")
        #expect(payload["transport_command"] as? String == "pause")
        #expect(payload["command_sent"] as? Bool == false)
    }
}

@MainActor
private final class TelemetryAPI: HearfulAPIProtocol, @unchecked Sendable {
    var sent: [[String: any Sendable]] = []
    var failNext = false

    func reportVoiceAttempt(_ event: [String: any Sendable]) async throws {
        if failNext { throw APIError(underlying: "offline") }
        sent.append(event)
    }

    func command(transcript: String) async throws -> CommandResponse { throw APIError(underlying: "unused") }
    func episode(id: Int) async throws -> Episode { throw APIError(underlying: "unused") }
    func articleText(episodeID: Int) async throws -> EpisodeText { throw APIError(underlying: "unused") }
    func recentEpisodes(limit: Int) async throws -> [Episode] { [] }
    func shows() async throws -> [Show] { [] }
    func episodes(showID: Int) async throws -> [Episode] { [] }
    func searchPodcasts(query: String) async throws -> [PodcastResult] { [] }
    func previewFeed(url: URL) async throws -> FeedPreview { throw APIError(underlying: "unused") }
    func subscribe(feedURL: URL) async throws -> Show { throw APIError(underlying: "unused") }
    func unsubscribe(showID: Int) async throws {}
    func login(appleIdentityToken: String, authorizationCode: String?) async throws -> AuthResponse {
        throw APIError(underlying: "unused")
    }
    func logout() async throws {}
    func me() async throws -> UserInfo { UserInfo(id: "u1", displayName: nil) }
    func deleteAccount() async throws {}
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws {}
}

@Suite("Telemetry reporter")
@MainActor
struct TelemetryReporterTests {
    private func store() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attempts-\(UUID().uuidString).json")
    }

    @Test func sendsAnAttempt() async throws {
        let api = TelemetryAPI()
        let file = store()
        defer { try? FileManager.default.removeItem(at: file) }
        let reporter = TelemetryReporter(api: api, store: file)

        reporter.report(VoiceAttempt())
        try await Task.sleep(for: .milliseconds(120))

        #expect(api.sent.count == 1)
    }

    @Test func keepsWhatItCouldNotSendAndDeliversItLater() async throws {
        // The events most worth having are the least likely to get through: a
        // spoken request that failed and a request that could not be sent
        // share a cause more often than not.
        let api = TelemetryAPI()
        let file = store()
        defer { try? FileManager.default.removeItem(at: file) }
        let reporter = TelemetryReporter(api: api, store: file)

        api.failNext = true
        reporter.report(VoiceAttempt())
        try await Task.sleep(for: .milliseconds(120))
        #expect(api.sent.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))

        api.failNext = false
        reporter.report(VoiceAttempt())
        try await Task.sleep(for: .milliseconds(120))

        // Both the queued one and the new one.
        #expect(api.sent.count == 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFailureToReportIsNeverThrownAtTheCaller() async throws {
        // Telemetry that costs a listener her podcast is worse than none.
        let api = TelemetryAPI()
        api.failNext = true
        let file = store()
        defer { try? FileManager.default.removeItem(at: file) }

        TelemetryReporter(api: api, store: file).report(VoiceAttempt())
        try await Task.sleep(for: .milliseconds(120))
        // Reaching here at all is the assertion: report() returns void and
        // swallows everything.
        #expect(api.sent.isEmpty)
    }
}
