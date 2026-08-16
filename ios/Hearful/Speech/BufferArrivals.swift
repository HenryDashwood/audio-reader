import Foundation

/// Counts audio buffers arriving from a microphone tap.
///
/// Zero is the one reading that cannot mean "she said nothing": a live tap
/// delivers buffers continuously, and silence is still audio. Zero means the
/// capture path never came up — which is a different failure, deserving a
/// different answer, and for a long time got the same one.
///
/// Locked rather than actor-isolated because the tap runs on the realtime
/// audio queue, which must never touch the main actor. `@unchecked Sendable`
/// is honest: the lock is the whole implementation.
final class BufferArrivals: @unchecked Sendable {
    /// How long to give the microphone to start delivering. Long enough to
    /// cover a cold audio route, short enough that she is not left waiting for
    /// a go-ahead that is never coming.
    static let wait: Double = 2.0
    /// Far below what anyone can hear as a delay before the tone.
    private static let poll = Duration.milliseconds(20)

    private let lock = NSLock()
    private var buffers = 0

    func record() {
        lock.lock()
        buffers += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers
    }

    /// Waits for the first buffer, returning false if none ever arrives.
    ///
    /// Polled rather than signalled, because waking a continuation from inside
    /// the tap would mean touching the main actor from the audio queue.
    ///
    /// Callers use this to hold the go-ahead tone until audio is genuinely
    /// flowing. `AVAudioEngine.start()` returns before the route is
    /// necessarily live, and a tone sounded then invites her to speak a whole
    /// sentence into a microphone that is not recording yet.
    func waitForFirst() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(Self.wait)
        while ContinuousClock.now < deadline {
            if count > 0 { return true }
            try? await Task.sleep(for: Self.poll)
        }
        return count > 0
    }
}
