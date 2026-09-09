import SwiftUI
import UIKit

/// Waits for VoiceOver's opening instruction before starting capture. A timer
/// is only a fallback for a missing notification, never a guess at speech speed.
@MainActor
final class VoiceOpeningAnnouncement: ObservableObject {
    static let message = "Ask Magpie. After the listening sound, say what you would like."
    @Published private(set) var isWaiting = false
    private let center: NotificationCenter
    private let voiceOverRunning: @MainActor () -> Bool
    private let announce: @MainActor (String) -> Void
    private var observers: [NSObjectProtocol] = []
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var requestID: UUID?

    init(
        center: NotificationCenter = .default,
        voiceOverRunning: @escaping @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning },
        announce: @escaping @MainActor (String) -> Void = {
            UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
                string: $0, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
        }
    ) {
        self.center = center
        self.voiceOverRunning = voiceOverRunning
        self.announce = announce
    }

    func prepare() async -> Bool {
        cancel()
        guard !Task.isCancelled else { return false }
        guard voiceOverRunning() else { return true }
        let id = UUID()
        requestID = id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
                let message = Self.message
                observers.append(center.addObserver(
                    forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
                ) { [weak self] notification in
                    let text = notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
                    let success = notification.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool
                    guard text == message else { return }
                    Task { @MainActor in self?.finish(id: id, ready: success == true) }
                })
                observers.append(center.addObserver(
                    forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, !self.voiceOverRunning() else { return }
                        self.finish(id: id, ready: true)
                    }
                })
                timeout = Task {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    // If VoiceOver interrupted the instruction or never reports
                    // completion, leave the accessible button available.
                    self.finish(id: id, ready: false)
                }
                announce(message)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, ready: false) }
        }
    }

    func cancel() {
        guard let id = requestID else { return }
        finish(id: id, ready: false)
    }

    private func finish(id: UUID, ready: Bool) {
        guard requestID == id else { return }
        requestID = nil
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        timeout?.cancel()
        timeout = nil
        isWaiting = false
        let pending = continuation
        continuation = nil
        pending?.resume(returning: ready)
    }
}
