import AVFoundation

/// Where synthesised samples go to be heard.
///
/// Separated from the synthesiser for the reason SilentSynthesizer exists: a
/// test must be able to drive a whole article through the reader without the
/// suite talking to the machine's speakers.
@MainActor
protocol KokoroAudioOutputting: AnyObject {
    /// Seconds of this utterance actually played. The reader's progress is a
    /// fraction of the chunk, and this is the numerator.
    var elapsed: TimeInterval { get }
    /// Everything enqueued has now been played to the end. Only ever called
    /// after `finishEnqueueing()`, so it means the utterance is over rather
    /// than that the renderer fell behind.
    var onDrained: (@MainActor () -> Void)? { get set }

    /// Adds a stretch of speech to the end of the queue. Playback starts on
    /// the first one rather than waiting for the last, which is what keeps
    /// time-to-first-word near a second on a long paragraph.
    func enqueue(_ audio: KokoroAudio)
    /// No more is coming for this utterance.
    func finishEnqueueing()
    func pause()
    func resume()
    /// Drops everything, played or not. Delivers no callback: a deliberate
    /// stop must not look like an utterance finishing.
    func stop()
}

/// The real one: an AVAudioEngine with a single player node, fed buffers as
/// they are rendered. Sequential buffers on one node play back to back with
/// no gap, so a paragraph split into sentences for latency still sounds like
/// a paragraph.
@MainActor
final class KokoroAudioEngineOutput: KokoroAudioOutputting {
    var onDrained: (@MainActor () -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var scheduled = 0
    private var played = 0
    private var isComplete = false
    /// The playhead stops moving while paused, so it is remembered rather
    /// than read.
    private var pausedElapsed: TimeInterval?

    init() {
        engine.attach(player)
    }

    var elapsed: TimeInterval {
        if let pausedElapsed { return pausedElapsed }
        guard let nodeTime = player.lastRenderTime,
            let playerTime = player.playerTime(forNodeTime: nodeTime),
            playerTime.sampleRate > 0
        else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    func enqueue(_ audio: KokoroAudio) {
        guard let buffer = Self.buffer(for: audio) else { return }
        do {
            try start(with: buffer.format)
        } catch {
            // Nothing will ever play, so let the reader move on rather than
            // sit on a chunk that has gone silent.
            finishEnqueueing()
            return
        }
        scheduled += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed() }
        }
        if !player.isPlaying && pausedElapsed == nil {
            player.play()
        }
    }

    func finishEnqueueing() {
        isComplete = true
        drainIfFinished()
    }

    func pause() {
        guard pausedElapsed == nil else { return }
        pausedElapsed = elapsed
        player.pause()
    }

    func resume() {
        guard pausedElapsed != nil else { return }
        pausedElapsed = nil
        player.play()
    }

    func stop() {
        // The callbacks for the dropped buffers still arrive; clearing the
        // counters first means they cannot add up to a drain.
        onDrained = nil
        scheduled = 0
        played = 0
        isComplete = false
        pausedElapsed = nil
        player.stop()
        if engine.isRunning { engine.stop() }
        format = nil
    }

    private func bufferPlayed() {
        played += 1
        drainIfFinished()
    }

    private func drainIfFinished() {
        guard isComplete, played >= scheduled else { return }
        let finished = onDrained
        onDrained = nil
        finished?()
    }

    /// The engine is connected at the first buffer's format because the
    /// sample rate belongs to the model, not to the hardware, and is not
    /// known until something has been rendered.
    private func start(with bufferFormat: AVAudioFormat) throws {
        if format == nil {
            try AudioSession.configureForPlayback()
            engine.connect(player, to: engine.mainMixerNode, format: bufferFormat)
            format = bufferFormat
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private static func buffer(for audio: KokoroAudio) -> AVAudioPCMBuffer? {
        guard !audio.samples.isEmpty,
            let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
            let channel = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        audio.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: source.count)
        }
        return buffer
    }
}
