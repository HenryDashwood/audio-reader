import Foundation
import Testing

@testable import Hearful

@Suite("Natural voice frees its models when idle")
struct NaturalVoiceIdleReleaseTests {
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func idle(_ delay: ControlledDelay, released: @escaping @MainActor () -> Void) -> NaturalVoiceIdleRelease {
        NaturalVoiceIdleRelease(after: .seconds(300), sleep: { try await delay.wait(for: $0) }, release: released)
    }

    @Test func idleFreesTheModelsOnceTheLimitPasses() async {
        let delay = ControlledDelay()
        var released = 0
        let idle = idle(delay) { released += 1 }
        idle.update(busy: false)
        await settle()
        #expect(delay.durations == [.seconds(300)])
        #expect(released == 0)
        delay.elapse()
        await settle()
        #expect(released == 1)
        #expect(!idle.isPending)
    }

    @Test func readingAgainBeforeTheLimitKeepsTheModels() async {
        let delay = ControlledDelay()
        var released = 0
        let idle = idle(delay) { released += 1 }
        idle.update(busy: false)
        await settle()
        idle.update(busy: true)
        await settle()
        #expect(delay.pendingCount == 0)
        #expect(!idle.isPending)
        delay.elapse()
        await settle()
        #expect(released == 0)
    }

    @Test func eachIdleSpellCountsFromItsStart() async {
        let delay = ControlledDelay()
        var released = 0
        let idle = idle(delay) { released += 1 }
        idle.update(busy: false)
        await settle()
        idle.update(busy: false)  // A second pause replaces the first countdown
        await settle()
        #expect(delay.durations.count == 2)
        #expect(delay.pendingCount == 1)
        delay.elapse()
        await settle()
        #expect(released == 1)
    }
}
