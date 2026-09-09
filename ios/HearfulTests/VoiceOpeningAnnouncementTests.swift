import Testing
import UIKit
@testable import Hearful

@Suite("VoiceOver conversation opening")
@MainActor
struct VoiceOpeningAnnouncementTests {
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
    }

    private func complete(_ center: NotificationCenter, text: String = VoiceOpeningAnnouncement.message, success: Bool = true) {
        center.post(name: UIAccessibility.announcementDidFinishNotification, object: nil, userInfo: [
            UIAccessibility.announcementStringValueUserInfoKey: text,
            UIAccessibility.announcementWasSuccessfulUserInfoKey: success,
        ])
    }

    @Test func waitsForItsOwnCompletedInstruction() async {
        let center = NotificationCenter()
        var spoken = ""
        let opening = VoiceOpeningAnnouncement(center: center, voiceOverRunning: { true }, announce: { spoken = $0 })
        let task = Task { await opening.prepare() }
        await settle { opening.isWaiting }
        #expect(spoken == VoiceOpeningAnnouncement.message)
        complete(center, text: "An unrelated announcement")
        await Task.yield()
        #expect(opening.isWaiting)
        complete(center)
        #expect(await task.value)
        #expect(!opening.isWaiting)
    }

    @Test func interruptedInstructionDoesNotStartRecording() async {
        let center = NotificationCenter()
        let opening = VoiceOpeningAnnouncement(center: center, voiceOverRunning: { true }, announce: { _ in })
        let task = Task { await opening.prepare() }
        await settle { opening.isWaiting }
        complete(center, success: false)
        #expect(await task.value == false)
    }

    @Test func closingCancelsTheWaitAndIgnoresLateAnnouncements() async {
        let center = NotificationCenter()
        let opening = VoiceOpeningAnnouncement(center: center, voiceOverRunning: { true }, announce: { _ in })
        let task = Task { await opening.prepare() }
        await settle { opening.isWaiting }
        opening.cancel()
        complete(center)
        #expect(await task.value == false)
        #expect(!opening.isWaiting)
    }

    @Test func cancellingTheViewTaskDoesNotHang() async {
        let opening = VoiceOpeningAnnouncement(voiceOverRunning: { true }, announce: { _ in })
        let task = Task { await opening.prepare() }
        await settle { opening.isWaiting }
        task.cancel()
        #expect(await task.value == false)
        #expect(!opening.isWaiting)
    }

    @Test func startsImmediatelyWithoutVoiceOver() async {
        var announced = false
        let opening = VoiceOpeningAnnouncement(voiceOverRunning: { false }, announce: { _ in announced = true })
        #expect(await opening.prepare())
        #expect(!announced)
    }
}
