import Foundation

/// One upload at a time for this presentation. The inbox owns the durable file;
/// dismissal cancels the request and closes the presentation to further feedback.
@MainActor
final class ShareSheetUpload {
    private(set) var isDismissed = false
    private(set) var task: Task<Void, Never>?

    func start<Value>(
        upload: @escaping @MainActor () async throws -> Value,
        completion: @escaping @MainActor (Result<Value, Error>) -> Void
    ) {
        guard !isDismissed, task == nil else { return }
        task = Task {
            defer { task = nil }
            guard !isDismissed else { return }
            let result: Result<Value, Error>
            do {
                result = .success(try await upload())
            } catch {
                result = .failure(error)
            }
            if !isDismissed { completion(result) }
        }
    }

    func dismiss() {
        isDismissed = true
        task?.cancel()
    }
}
