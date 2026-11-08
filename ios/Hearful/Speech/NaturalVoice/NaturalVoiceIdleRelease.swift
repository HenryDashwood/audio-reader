import Foundation

/// Frees the natural voice once nothing has used it for a while. A paused article
/// otherwise kept the models for as long as the app lived: on an iPhone 18 Pro,
/// freeing them took Magpie's footprint from 179 MB to 90 MB, which counts most
/// once the screen locks and iOS lowers the app's allowance. Resuming afterwards
/// plays the audio already queued while the models load again; the gap was under
/// a second.
@MainActor
final class NaturalVoiceIdleRelease {
    private let limit: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let release: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    init(
        after limit: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        release: @escaping @MainActor () -> Void
    ) {
        self.limit = limit
        self.sleep = sleep
        self.release = release
    }

    /// Call whenever reading starts or stops. Busy keeps the models; idle frees
    /// them after the limit, counted again from the latest call.
    func update(busy: Bool) {
        pending?.cancel()
        pending = nil
        guard !busy else { return }
        pending = Task { [weak self, limit, sleep] in
            do { try await sleep(limit) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.release()
        }
    }

    var isPending: Bool { pending != nil }
}
