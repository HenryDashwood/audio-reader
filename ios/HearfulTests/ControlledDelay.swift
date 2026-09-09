import Foundation

/// A manually completed delay: elapsed wall time has no effect on deadline or cue tests.
/// Each wait is tracked separately because a follow-up can start while the
/// previous turn's cancelled delay is still unwinding.
@MainActor
final class ControlledDelay {
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var durations: [Duration] = []
    private(set) var finishedCount = 0
    var pendingCount: Int { pending.count }

    func wait(for duration: Duration) async throws {
        let id = UUID()
        durations.append(duration)
        defer { finishedCount += 1 }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func elapse() {
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

