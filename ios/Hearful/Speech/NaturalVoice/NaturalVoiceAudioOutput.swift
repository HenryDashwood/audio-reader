import AVFoundation
import os

private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "natural-voice")

@MainActor
protocol NaturalVoiceOutput: AnyObject {
    var onDrained: (@MainActor () -> Void)? { get set }
    /// The audio hardware went away under queued speech, which will now never
    /// play or report finishing. Only a fresh engine recovers it.
    var onFailure: (@MainActor () -> Void)? { get set }
    var position: Int { get }
    /// Speech is queued and nothing is holding it back: the clock should move.
    /// False while paused or waiting for rendering to catch up.
    var isExpectingSound: Bool { get }
    func setRate(_ rate: Float)
    func enqueue(_ samples: [Float], continuesToNextChunk: Bool) throws
    func finishEnqueueing()
    func pause()
    func resume()
    func stop()
}

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
final class NaturalVoiceAudioOutput: NaturalVoiceOutput {
    /// Everything enqueued has finished. Continuing chunks hand off after
    /// rendering; the final chunk waits until playback reaches the device.
    /// Only after `finishEnqueueing()`, so a rendering delay cannot finish it.
    var onDrained: (@MainActor () -> Void)?
    var onFailure: (@MainActor () -> Void)?

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
    /// Paused here because rendering fell behind, rather than by the listener.
    private var isHeld = false
    /// The engine stopped itself for a hardware change while speech was queued.
    private var isBroken = false
    private var configurationObserver: NSObjectProtocol?

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        // A route or sample-rate change (Bluetooth connecting, a car, AirPods
        // switching device) stops the engine without a word to its player
        // node: the queued buffers never play and never complete. The reader
        // sat "playing" in silence, and pause/resume could not revive it.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    isolated deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    var isExpectingSound: Bool { pausedAt == nil && !isHeld && played < scheduled }

    #if HEARFUL_VOICE_TIMING
        func beginTimingCapture(_ capture: NaturalVoiceTimingCapture) {
            // The audio thread owns this callback; the capture protects its
            // shared state rather than carrying main-actor isolation here.
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
                capture.append(buffer)
            }
        }

        func endTimingCapture() {
            engine.mainMixerNode.removeTap(onBus: 0)
        }
    #endif

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

    func enqueue(_ samples: [Float], continuesToNextChunk: Bool) throws {
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: $0.count) }
        try connect()
        if pausedAt == nil { try start() }  // Not while paused: a running engine says audio is playing
        scheduled += 1
        let scheduledGeneration = generation
        // Waiting for device playback at every chunk adds the downstream
        // processing and output-device latency to every passage boundary.
        // Hand continuing speech over once its samples have been rendered;
        // keep the final completion tied to sound actually finishing.
        let completion: AVAudioPlayerNodeCompletionCallbackType = continuesToNextChunk ? .dataRendered : .dataPlayedBack
        player.scheduleBuffer(buffer, completionCallbackType: completion) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(generation: scheduledGeneration) }
        }
        if !player.isPlaying, pausedAt == nil {
            player.play()
            isHeld = false
        }
    }

    func finishEnqueueing() {
        isComplete = true
        drainIfFinished()
    }

    /// Pauses the engine as well as the player. A running engine plays silence, and iOS takes an app that is
    /// playing silence to be playing: the lock screen's button went back to Pause, and pressing it did nothing.
    func pause() {
        guard pausedAt == nil else { return }
        pausedAt = position
        player.pause()
        engine.pause()
    }

    func resume() {
        guard pausedAt != nil else { return }
        pausedAt = nil
        isHeld = false  // play() below releases a hold too
        if isBroken {
            fail()
            return
        }
        do {
            try start()
        } catch {
            log.error("Natural voice could not restart its audio: \(error.localizedDescription, privacy: .public)")
        }
        player.play()
    }

    /// Drops everything without a callback, and leaves the engine running for the next chunk.
    func stop() {
        onDrained = nil
        onFailure = nil
        isBroken = false  // The next enqueue restarts the engine with fresh buffers
        generation += 1
        scheduled = 0
        played = 0
        isComplete = false
        pausedAt = nil
        isHeld = false
        player.stop()
    }

    private func bufferPlayed(generation completed: Int) {
        guard completed == generation else { return }
        played += 1
        if !isComplete, played >= scheduled {
            player.pause()  // Rendering fell behind: hold the clock until the next sentence arrives
            isHeld = true
        }
        drainIfFinished()
    }

    private func drainIfFinished() {
        guard isComplete, played >= scheduled else { return }
        let finished = onDrained
        onDrained = nil
        finished?()
    }

    private func configurationChanged() {
        log.error("Natural voice audio engine stopped for a configuration change (running: \(self.engine.isRunning, privacy: .public))")
        guard played < scheduled else { return }  // Nothing queued was lost; the next enqueue restarts it
        if pausedAt == nil {
            fail()
        } else {
            isBroken = true  // Paused: report it when she presses play
        }
    }

    private func fail() {
        let failure = onFailure
        onFailure = nil
        failure?()
    }

    private func connect() throws {
        guard !isConnected else { return }
        try AudioSession.configureForPlayback()
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        isConnected = true
    }

    private func start() throws {
        try connect()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }
}
