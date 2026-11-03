import AVFoundation

/// The downloadable voice's speaker: an AVAudioEngine with one player node, fed
/// a sentence at a time as each is rendered. Buffers scheduled on one node play
/// back to back with no gap, so a chunk rendered in sentences still sounds like
/// a paragraph.
///
/// From the August Kokoro prototype, which found the two things that matter
/// here: connect the engine once and leave it running between chunks (tearing
/// it down was an audible gap and a chirp), and speed speech up after rendering
/// rather than asking the model to talk faster.
@MainActor
final class NaturalVoiceAudioOutput {
    /// Everything enqueued has played. Only after `finishEnqueueing()`, so it
    /// means the utterance is over rather than that rendering fell behind.
    var onDrained: (@MainActor () -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: NaturalVoiceEngine.sampleRate, channels: 1)!
    private var isConnected = false
    private var scheduled = 0
    private var played = 0
    private var isComplete = false
    /// Completion callbacks still arrive for buffers `stop()` dropped; a generation keeps them out of the next
    /// utterance's counts.
    private var generation = 0
    private var pausedAt: Int?

    init() {
        engine.attach(player)
        engine.attach(timePitch)
    }

    /// How fast to play, pitch unchanged. Speech is rendered at 1x.
    func setRate(_ rate: Float) {
        timePitch.rate = min(max(rate, 0.5), 3)
    }

    /// Samples of this utterance played so far, at the rate they were rendered.
    var position: Int {
        if let pausedAt { return pausedAt }
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return max(0, Int(time.sampleTime))
    }

    func enqueue(_ samples: [Float]) throws {
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: $0.count) }
        try start()
        scheduled += 1
        let scheduledGeneration = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(generation: scheduledGeneration) }
        }
        if !player.isPlaying, pausedAt == nil { player.play() }
    }

    func finishEnqueueing() {
        isComplete = true
        drainIfFinished()
    }

    func pause() {
        guard pausedAt == nil else { return }
        pausedAt = position
        player.pause()
    }

    func resume() {
        guard pausedAt != nil else { return }
        pausedAt = nil
        player.play()
    }

    /// Drops everything without a callback, and leaves the engine running for the next chunk.
    func stop() {
        onDrained = nil
        generation += 1
        scheduled = 0
        played = 0
        isComplete = false
        pausedAt = nil
        player.stop()
    }

    private func bufferPlayed(generation completed: Int) {
        guard completed == generation else { return }
        played += 1
        if !isComplete, played >= scheduled {
            player.pause()  // Rendering fell behind: hold the clock until the next sentence arrives
        }
        drainIfFinished()
    }

    private func drainIfFinished() {
        guard isComplete, played >= scheduled else { return }
        let finished = onDrained
        onDrained = nil
        finished?()
    }

    private func start() throws {
        if !isConnected {
            try AudioSession.configureForPlayback()
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            isConnected = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }
}
