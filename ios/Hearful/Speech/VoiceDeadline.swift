import Foundation

/// A cancelled framework operation is not guaranteed to return promptly.
/// Resolve our caller independently, while cancelling the underlying work.
@MainActor
private final class VoiceWait<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Error>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var completed = false

    func finish(_ result: Result<Value, Error>) {
        guard !completed else { return }
        completed = true
        let pending = continuation
        continuation = nil
        work?.cancel()
        timer?.cancel()
        pending?.resume(with: result)
    }
}

struct VoiceTimeout: Error {}

@MainActor
func withVoiceDeadline<Value: Sendable>(
    seconds: Double,
    operation: @escaping @MainActor @Sendable () async throws -> Value
) async throws -> Value {
    let wait = VoiceWait<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            wait.continuation = continuation
            wait.work = Task {
                do { wait.finish(.success(try await operation())) }
                catch { wait.finish(.failure(error)) }
            }
            wait.timer = Task {
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return }
                wait.finish(.failure(VoiceTimeout()))
            }
        }
    } onCancel: {
        Task { @MainActor in wait.finish(.failure(CancellationError())) }
    }
}
