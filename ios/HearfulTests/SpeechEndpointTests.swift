import Testing
@testable import Hearful

struct SpeechEndpointTests {
    @Test func ongoingSpeechOutlastsAStaleTranscript() {
        var endpoint = SpeechEndpoint()
        let decision1 = !endpoint.shouldFinish(speechDetected: true, audioEnd: 2, hasTranscript: true, settledControl: false)
        #expect(decision1)
        let decision2 = !endpoint.shouldFinish(speechDetected: true, audioEnd: 10, hasTranscript: true, settledControl: false)
        #expect(decision2)
        let decision3 = !endpoint.shouldFinish(speechDetected: false, audioEnd: 11, hasTranscript: true, settledControl: false)
        #expect(decision3)
        let decision4 = endpoint.shouldFinish(speechDetected: false, audioEnd: 11.6, hasTranscript: true, settledControl: false)
        #expect(decision4)
    }

    @Test func onlySettledControlsUseTheShortPause() {
        var endpoint = SpeechEndpoint()
        _ = endpoint.shouldFinish(speechDetected: true, audioEnd: 2, hasTranscript: true, settledControl: false)
        let decision5 = !endpoint.shouldFinish(speechDetected: false, audioEnd: 2.8, hasTranscript: true, settledControl: false)
        #expect(decision5)
        let decision6 = endpoint.shouldFinish(speechDetected: false, audioEnd: 2.8, hasTranscript: true, settledControl: true)
        #expect(decision6)
    }

    @Test func silenceBeforeSpeechCannotFinishARequest() {
        var endpoint = SpeechEndpoint()
        let decision7 = !endpoint.shouldFinish(speechDetected: false, audioEnd: 10, hasTranscript: false, settledControl: false)
        #expect(decision7)
    }
}
