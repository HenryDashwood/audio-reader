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
    /// Playback caught up with the renderer before the utterance was fully
    /// enqueued. The synthesiser uses this to rebuild a reserve instead of
    /// feeding the player one late buffer at a time.
    var onUnderrun: (@MainActor () -> Void)? { get set }

    /// How fast to play, with the pitch left alone. Speech is always rendered
    /// at 1x and sped up here.
    func setRate(_ rate: Float)

    /// Adds a stretch of speech to the end of the queue. Playback starts on
    /// the first one rather than waiting for the last, which is what keeps
    /// time-to-first-word near a second on a long paragraph.
    func enqueue(_ audio: KokoroAudio)
    /// No more is coming for this utterance.
    func finishEnqueueing()
    func pause()
    func resume()
    /// Drops everything, played or not. Delivers no callback: a deliberate
    /// stop must not look like an utterance finishing. Leaves the engine up:
    /// the reader stops between every chunk, and tearing down there is
    /// audible.
    func stop()
    /// Stops and releases the audio engine, for when reading has ended
    /// rather than moved on.
    func shutDown()
}

/// The real one: an AVAudioEngine with a single player node, fed buffers as
/// they are rendered. Sequential buffers on one node play back to back with
/// no gap, so a paragraph split into sentences for latency still sounds like
/// a paragraph.
@MainActor
final class KokoroAudioEngineOutput: KokoroAudioOutputting {
    var onDrained: (@MainActor () -> Void)?
    var onUnderrun: (@MainActor () -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Speeds playback up without raising the pitch. The model has its own
    /// speed control and it is worse: asking it to talk quickly makes it slur
    /// and swallow syllables, where stretching finished audio does not.
    private let timePitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?
    private var scheduled = 0
    private var played = 0
    private var isComplete = false
    /// Completion callbacks still arrive for buffers dropped by `stop()`.
    /// A generation keeps those callbacks out of a new utterance's counters.
    private var generation = 0
    /// The playhead stops moving while paused, so it is remembered rather
    /// than read.
    private var pausedElapsed: TimeInterval?

    init() {
        engine.attach(player)
        engine.attach(timePitch)
    }

    func setRate(_ rate: Float) {
        timePitch.rate = min(max(rate, 0.5), 3)
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
        let scheduledGeneration = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(generation: scheduledGeneration) }
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

    /// Stops what is playing and leaves the engine running.
    ///
    /// Deliberately does not tear the engine down. The reader stops the
    /// synthesiser at the start of every chunk, so stopping the engine here
    /// meant re-activating the audio session and reconnecting the player
    /// between every chunk of an article — which is audible: a gap, and a
    /// chirp as the reconnected node picks up the new format.
    func stop() {
        // The callbacks for dropped buffers still arrive. Advancing the
        // generation makes them harmless to whatever is scheduled next.
        onDrained = nil
        onUnderrun = nil
        generation += 1
        scheduled = 0
        played = 0
        isComplete = false
        pausedElapsed = nil
        player.stop()
    }

    /// Gives the audio session back. For when nothing is being read any more,
    /// rather than between two chunks of the same article.
    func shutDown() {
        stop()
        if engine.isRunning { engine.stop() }
        format = nil
    }

    /// Debug: records what actually reaches the speaker, past the scheduling,
    /// the mixer and any rate conversion — the part a rendered WAV cannot tell
    /// you anything about.
    ///
    /// Collects samples rather than using AVAudioFile: the mixer's format is
    /// non-interleaved, which AVAudioFile will not write, and finding that out
    /// costs a SIGTRAP rather than an error.
    nonisolated final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        var sampleRate: Double = 0

        func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            lock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
            lock.unlock()
        }

        func take() -> KokoroAudio {
            lock.lock(); defer { lock.unlock() }
            return KokoroAudio(samples: samples, sampleRate: sampleRate)
        }
    }

    func startCapture() -> Capture? {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        let capture = Capture()
        capture.sampleRate = format.sampleRate
        engine.mainMixerNode.removeTap(onBus: 0)
        // @Sendable: the tap is called on an audio thread, and a closure made
        // inside this @MainActor class would otherwise inherit main-actor
        // isolation and trap on the first buffer.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
            @Sendable buffer, _ in
            capture.append(buffer)
        }
        return capture
    }

    func stopCapture() {
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    private func bufferPlayed(generation completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        played += 1
        if !isComplete, played >= scheduled {
            // Stop the node's clock while no speech is available. Enqueueing
            // the rebuilt reserve starts it again unless the listener paused.
            player.pause()
            onUnderrun?()
        }
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
    /// known until something has been rendered. Connected once and then left
    /// alone: reconnecting a running engine is what the chirp was.
    private func start(with bufferFormat: AVAudioFormat) throws {
        if format != bufferFormat {
            try AudioSession.configureForPlayback()
            engine.connect(player, to: timePitch, format: bufferFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: bufferFormat)
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
