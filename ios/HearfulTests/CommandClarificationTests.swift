import Foundation
import Testing
@testable import Hearful

@Suite("Structured voice clarification")
struct CommandClarificationTests {
    @Test func choicesDecodeAndAnswerUsesANewRequestID() throws {
        let json = #"{"action":"unknown","spoken_response":"History or Politics?","expects_reply":true,"status":"needs_clarification","clarification":{"id":"question-id","question":"History or Politics?","choices":[{"id":"10","label":"History"},{"id":"20","label":"Politics"}],"expires_at":"2026-09-21T00:00:00Z"}}"#
        let response = try JSONDecoder().decode(CommandResponse.self, from: Data(json.utf8))
        let question = try #require(response.clarification)
        #expect(question.choices.map(\.label) == ["History", "Politics"])
        let request = CommandRequest(clarificationID: question.id, selectedOptionID: "20",
                                     transcript: "Politics", requestID: UUID().uuidString)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(body["clarification_id"] as? String == "question-id")
        #expect(body["selected_option_id"] as? String == "20")
        #expect(body["timezone"] as? String == TimeZone.current.identifier)
        #expect(body["request_id"] as? String != question.id)
    }

    @Test func olderResponsesStillDecode() throws {
        let response = try JSONDecoder().decode(CommandResponse.self,
            from: Data(#"{"action":"unknown","spoken_response":"Done."}"#.utf8))
        #expect(response.clarification == nil)
        #expect(response.status == nil)
    }

    @Test @MainActor func questionsAreIsolatedByAccountAndServer() {
        let server = URL(string: "https://clarification.test")!
        let alice = VoiceSessionContext.forAccount("clarification-alice", server: server)
        alice.clarification = CommandClarification(id: "private", question: "Which?", choices: [], expiresAt: "2026-09-21T00:00:00Z")
        #expect(VoiceSessionContext.forAccount("clarification-bob", server: server).clarification == nil)
        #expect(VoiceSessionContext.forAccount("clarification-alice", server: URL(string: "https://other.test")!).clarification == nil)
    }
}
