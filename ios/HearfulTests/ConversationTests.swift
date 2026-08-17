import Foundation
import Testing

@testable import Hearful

@Suite("The exchange so far")
struct ConversationTests {
    @Test func recordsBothSidesInOrder() async {
        var conversation = Conversation()
        conversation.sheSaid("play the rest is history")
        conversation.appSaid("Which episode?")
        conversation.sheSaid("the one about Agincourt")

        #expect(
            conversation.turns == [
                ConversationTurn(speaker: .her, text: "play the rest is history"),
                ConversationTurn(speaker: .app, text: "Which episode?"),
                ConversationTurn(speaker: .her, text: "the one about Agincourt"),
            ])
    }

    @Test func startsEmpty() {
        #expect(Conversation().isEmpty)
        #expect(Conversation().payload.isEmpty)
    }

    @Test func blankLinesAreNotRecorded() {
        // Some actions are confirmed by the audio changing rather than by a
        // sentence. An empty turn would be a row she cannot read and a pair of
        // empty quotes in the prompt.
        var conversation = Conversation()
        conversation.appSaid("")
        conversation.sheSaid("   \n ")

        #expect(conversation.isEmpty)
    }

    @Test func onlyTheMostRecentTurnsTravelWithARequest() {
        // The screen keeps the lot; the request does not need to.
        var conversation = Conversation()
        for index in 0..<(Conversation.sent + 4) {
            conversation.sheSaid("line \(index)")
        }

        #expect(conversation.turns.count == Conversation.sent + 4)
        #expect(conversation.payload.count == Conversation.sent)
        #expect(conversation.payload.first?.text == "line 4")
        #expect(conversation.payload.last?.text == "line \(Conversation.sent + 3)")
    }

    @Test func aLongSilenceEndsTheSubject() async {
        // A tap two minutes later is a new request, and reading it against
        // lines she has stopped thinking about is worse than reading it alone.
        let started = ContinuousClock.now
        var conversation = Conversation()
        conversation.sheSaid("play the rest is history", at: started)
        conversation.appSaid("Which episode?", at: started)

        conversation.forgetIfStale(now: started + Conversation.forgetAfter + .seconds(1))

        #expect(conversation.isEmpty)
    }

    @Test func aPromptAnswerContinuesTheSubject() async {
        let started = ContinuousClock.now
        var conversation = Conversation()
        conversation.sheSaid("play the rest is history", at: started)
        conversation.appSaid("Which episode?", at: started)

        conversation.forgetIfStale(now: started + .seconds(3))

        #expect(conversation.turns.count == 2)
    }

    @Test func stalenessIsMeasuredFromTheLastThingSaid() async {
        // Not from the start of the exchange: a long conversation is not a
        // stale one, and clearing it mid-sentence would strand her answer.
        let started = ContinuousClock.now
        var conversation = Conversation()
        conversation.sheSaid("subscribe to something", at: started)
        conversation.appSaid("Which show?", at: started + Conversation.forgetAfter - .seconds(5))

        conversation.forgetIfStale(now: started + Conversation.forgetAfter + .seconds(1))

        #expect(conversation.turns.count == 2)
    }

    @Test func anEmptyExchangeIsNeverStale() {
        // Nothing has been said, so there is no gap to measure and nothing to
        // drop — and no `lastSpoke` to read.
        var conversation = Conversation()
        conversation.forgetIfStale(now: .now + .seconds(10_000))
        #expect(conversation.isEmpty)
    }

    @Test func waitingOnHerIsTheAppHavingSpokenLast() {
        var conversation = Conversation()
        #expect(!conversation.isAwaitingHer)
        conversation.sheSaid("play something")
        #expect(!conversation.isAwaitingHer)
        conversation.appSaid("Which show?")
        #expect(conversation.isAwaitingHer)
    }

    @Test func turnsEncodeAsTheBackendReadsThem() throws {
        let encoded = try JSONEncoder().encode([
            ConversationTurn(speaker: .her, text: "play it"),
            ConversationTurn(speaker: .app, text: "Which one?"),
        ])
        let json = try JSONSerialization.jsonObject(with: encoded) as? [[String: String]]

        #expect(json == [
            ["speaker": "her", "text": "play it"],
            ["speaker": "app", "text": "Which one?"],
        ])
    }
}
