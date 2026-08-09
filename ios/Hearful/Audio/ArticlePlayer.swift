import AVFoundation
import MediaPlayer
import UIKit

/// Reads articles aloud with the on-device voice, presenting itself to the
/// rest of the app exactly like audio playback: an (estimated) timeline in
/// seconds, so the scrubber, skip buttons, saved positions and lock screen
/// behave the same as for podcast audio.
///
/// Speech is always synthesised at 1× and played through a pitch-preserving
/// time-stretch (AVAudioUnitTimePitch) — the same approach the podcast player
/// uses for streamed audio. Raising the synthesiser's own rate instead makes
/// the voice clip and garble; stretching rendered audio keeps it natural at
/// any speed, and rate changes apply instantly mid-sentence.
///
/// If article audio is ever rendered server-side (ElevenLabs et al.), those
/// items arrive as ordinary episodes with an audio_url and never reach this
/// class — nothing here needs to change.
@MainActor
final class ArticlePlayer: NSObject, ObservableObject {
    /// One player for the whole app, for the same reason as AudioPlayer: Siri
    /// intents run without any UI.
    static let shared = ArticlePlayer()

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var isScrubbing = false
    @Published private(set) var playbackRate: Float = 1.0

    /// Renders utterances to PCM buffers; never plays audio itself.
    private let synthesizer = AVSpeechSynthesizer()
    /// Speaks failure messages aloud, separate from the rendering pipeline.
    private let announcer = AVSpeechSynthesizer()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var engineFormat: AVAudioFormat?

    private let api: HearfulAPIProtocol
    private var script: ArticleScript?
    private var chunkIndex = 0
    /// True once she asked for sound: speech starts as soon as text arrives.
    private var wantsPlayback = false
    /// Bumped whenever playback restarts somewhere else (seek, new episode),
    /// so stale render tasks and buffer-completion callbacks are ignored.
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var progressTimer: Timer?
    /// Rendered chunks, kept a little ahead so scheduling never waits.
    private var rendered: [Int: [AVAudioPCMBuffer]] = [:]
    /// The speaking rate the cache was rendered at; a rate change makes
    /// every cached chunk stale.
    private var renderedAtRate: Float = 1.0

    // Gapless schedule state. Chunks are appended to the running node ahead
    // of time and the node is never stopped between them — stopping flushes
    // the time-stretcher's tail and audibly clips word endings.
    /// The highest chunk index whose audio is scheduled on the node.
    private var scheduledThrough: Int?
    /// Chunk indexes currently being rendered for scheduling.
    private var scheduling: Set<Int> = []
    /// Where each scheduled chunk starts, in the node's sample clock.
    private var chunkStartFrames: [Int: AVAudioFramePosition] = [:]
    private var chunkFrames: [Int: AVAudioFramePosition] = [:]
    private var totalScheduledFrames: AVAudioFramePosition = 0

    init(api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)) {
        self.api = api
        super.init()
        engine.attach(playerNode)
        engine.attach(timePitch)
        // Same stored preference as AudioPlayer: her speed is her speed,
        // whether the thing playing is streamed or spoken.
        let stored = UserDefaults.standard.float(forKey: "HearfulPlaybackRate")
        playbackRate = stored > 0 ? stored : 1.0
        // Speed comes from the synthesiser speaking faster (how VoiceOver and
        // Speak Screen do it — natural prosody at any speed), not from
        // stretching rendered audio, which always smears. The time-pitch node
        // stays in the chain, inert, in case fine correction is ever wanted.
        timePitch.rate = 1.0
        // Route changes and the recogniser borrowing the session invalidate
        // the engine's graph; rebuild rather than trusting stale connections.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    /// The graph is stale: force a reconnect on next start, and if speech
    /// was sounding, rebuild from the current chunk straight away.
    private func engineConfigurationChanged() {
        engineFormat = nil
        if wantsPlayback, script != nil {
            startPlayback(at: chunkIndex)
        } else {
            resetSchedule()
        }
    }

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    // MARK: - Playback

    /// Loads the article's text without speaking, so the network fetch
    /// overlaps the spoken confirmation instead of following it.
    func prepare(_ episode: Episode) {
        guard episode.id != currentEpisode?.id else { return }
        load(episode, andPlay: false)
    }

    /// Brings back the article she was reading, paused, with her position.
    /// Text is not fetched until she actually resumes.
    func restore(_ episode: Episode) {
        guard currentEpisode == nil else { return }
        currentEpisode = episode
        currentTime = episode.completed == true ? 0 : (episode.positionSeconds ?? 0)
        publishNowPlaying(episode)
    }

    func play(_ episode: Episode) {
        try? AudioSession.configureForPlayback()
        if episode.id == currentEpisode?.id, script != nil {
            wantsPlayback = true
            startPlayback(at: chunkIndex)
            return
        }
        load(episode, andPlay: true)
    }

    func pause() {
        wantsPlayback = false
        playerNode.pause()
        // Release the audio hardware, not just the node: the speech
        // recognisers run their own engine on the microphone, and flipping
        // the session to record mode while this engine still holds a live
        // IO unit crashes deep in CoreAudio.
        engine.pause()
        isPlaying = false
        stopProgressTimer()
        updateNowPlayingPosition()
    }

    func resume() {
        guard let episode = currentEpisode else { return }
        try? AudioSession.configureForPlayback()
        wantsPlayback = true
        if script == nil {
            // Restored at launch: the text has not been fetched yet.
            load(episode, andPlay: true)
        } else if scheduledThrough != nil {
            // Paused mid-chunk with the schedule intact: carry on from the
            // same word.
            do {
                if !engine.isRunning { try engine.start() }
                playerNode.play()
                isPlaying = true
                startProgressTimer()
                updateNowPlayingPosition()
            } catch {
                // The graph was invalidated while paused (a phone call, the
                // recogniser borrowing the session): rebuild cleanly.
                startPlayback(at: chunkIndex)
            }
        } else {
            startPlayback(at: chunkIndex)
        }
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: TimeInterval) {
        guard let script, let index = script.index(at: min(max(seconds, 0), script.duration)) else {
            // Text not loaded yet (restored, never resumed): remember where
            // she wants to be, and the load will start there.
            currentTime = max(seconds, 0)
            return
        }
        chunkIndex = index
        currentTime = script.chunks[index].start
        if wantsPlayback {
            startPlayback(at: index)
        } else {
            generation += 1
            resetSchedule()
            updateNowPlayingPosition()
        }
    }

    /// Re-renders upcoming speech at the new speaking rate. The current
    /// chunk restarts so the change is heard immediately — a small rewind,
    /// the price of the voice actually speaking faster rather than being
    /// stretched.
    func setPlaybackRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 3.0)
        guard clamped != playbackRate else { return }
        playbackRate = clamped
        if wantsPlayback, script != nil {
            startPlayback(at: chunkIndex)
        }
        updateNowPlayingPosition()
    }

    /// The synthesiser's rate knob for a listener-facing multiplier.
    ///
    /// The scale is nonlinear: 0.0–1.0, where 0.5 is normal speech and 1.0
    /// is roughly four times it. Mapping the multiplier onto that quarter
    /// slope keeps spoken speeds close to their labels; being a shade off is
    /// fine — what matters is natural-sounding steps, not stopwatch accuracy.
    static func utteranceRate(for multiplier: Float) -> Float {
        if multiplier == 1 { return AVSpeechUtteranceDefaultSpeechRate }
        if multiplier > 1 {
            return min(0.5 + (multiplier - 1) / 4, 0.95)
        }
        // Below normal the same slope feels too subtle; slowing is rare and
        // gentle steps are kinder than a crawl.
        return max(0.5 - (1 - multiplier) * 0.3, 0.3)
    }

    /// Called when audio playback takes over: stop making sound, keep state.
    func deactivate() {
        wantsPlayback = false
        generation += 1
        resetSchedule()
        if engine.isRunning { engine.pause() }
        isPlaying = false
        stopProgressTimer()
    }

    // MARK: - Loading

    private func load(_ episode: Episode, andPlay: Bool) {
        loadTask?.cancel()
        deactivate()
        wantsPlayback = andPlay
        currentEpisode = episode
        script = nil
        rendered = [:]
        chunkIndex = 0
        // Resume where she left off, same rules as audio: not if finished,
        // and not for the first few seconds.
        let resumeAt = episode.completed == true ? 0 : (episode.positionSeconds ?? 0)
        currentTime = resumeAt > 5 ? resumeAt : 0
        duration = 0
        PlaybackRestore.remember(episodeID: episode.id)
        publishNowPlaying(episode)

        loadTask = Task { [weak self, api] in
            do {
                let article = try await api.articleText(episodeID: episode.id)
                guard let self, !Task.isCancelled, self.currentEpisode?.id == episode.id else {
                    return
                }
                self.scriptLoaded(ArticleScript(text: article.text))
            } catch {
                guard let self, !Task.isCancelled, self.currentEpisode?.id == episode.id else {
                    return
                }
                self.loadFailed(with: error)
            }
        }
    }

    private func scriptLoaded(_ loaded: ArticleScript) {
        guard !loaded.isEmpty else {
            loadFailed(with: APIError(underlying: "article text was empty"))
            return
        }
        script = loaded
        duration = loaded.duration
        // Land on the chunk her saved position falls in; start exactly at its
        // beginning so no words are silently skipped.
        if let index = loaded.index(at: min(currentTime, loaded.duration)) {
            chunkIndex = index
            currentTime = loaded.chunks[index].start
        }
        updateNowPlayingPosition()
        if wantsPlayback {
            startPlayback(at: chunkIndex)
        }
    }

    private func loadFailed(with error: Error) {
        wantsPlayback = false
        isPlaying = false
        // Silence tells a blind listener nothing: read the failure out.
        let message =
            (error as? APIError)?.spokenResponse
            ?? "Sorry, I could not get the text of that article."
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        try? AudioSession.configureForPlayback()
        announcer.speak(utterance)
    }

    // MARK: - Rendering and scheduling

    /// Stops whatever is sounding and plays chunk `index` from its start.
    /// The only place (besides seek and deactivate) that stops the node:
    /// mid-article, chunks are appended to the running schedule instead.
    private func startPlayback(at index: Int) {
        guard let script, index < script.chunks.count else { return }
        generation += 1
        let gen = generation
        resetSchedule()
        chunkIndex = index
        currentTime = script.chunks[index].start
        updateNowPlayingPosition()

        Task { [weak self] in
            guard let self else { return }
            guard let buffers = await self.renderedChunk(index), !buffers.isEmpty else {
                if self.generation == gen {
                    self.loadFailed(with: APIError(underlying: "speech rendering produced no audio"))
                }
                return
            }
            guard self.generation == gen, self.wantsPlayback else { return }
            guard self.startEngine(with: buffers[0].format) else {
                self.loadFailed(with: APIError(underlying: "audio engine would not start"))
                return
            }
            // With the engine guaranteed running, stop() reliably clears
            // anything stale and restarts the node's sample clock at zero.
            self.playerNode.stop()
            self.append(buffers, chunk: index, generation: gen)
            self.playerNode.play()
            self.isPlaying = true
            self.startProgressTimer()
            self.updateNowPlayingPosition()
            self.ensureScheduledAhead()
        }
    }

    /// Appends one rendered chunk to the node's schedule, extending the
    /// continuous sample timeline.
    private func append(_ buffers: [AVAudioPCMBuffer], chunk index: Int, generation gen: Int) {
        chunkStartFrames[index] = totalScheduledFrames
        let frames = buffers.reduce(AVAudioFramePosition(0)) {
            $0 + AVAudioFramePosition($1.frameLength)
        }
        chunkFrames[index] = frames
        totalScheduledFrames += frames
        for (position, buffer) in buffers.enumerated() {
            if position == buffers.count - 1 {
                // .dataPlayedBack: fires when the audio has actually sounded.
                // Used only for bookkeeping and end-of-article — never to
                // stop or start audio, so its timing cannot clip anything.
                playerNode.scheduleBuffer(
                    buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor in self?.chunkBuffersPlayed(index, generation: gen) }
                }
            } else {
                playerNode.scheduleBuffer(buffer)
            }
        }
        scheduledThrough = index
    }

    /// Keeps the node's schedule one chunk ahead of what is sounding, so the
    /// next chunk begins seamlessly the moment the current one ends.
    private func ensureScheduledAhead() {
        guard wantsPlayback, let script, let through = scheduledThrough,
            through < script.chunks.count - 1,
            through - chunkIndex < 2,
            !scheduling.contains(through + 1)
        else { return }
        let next = through + 1
        scheduling.insert(next)
        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            let buffers = await self.renderedChunk(next)
            self.scheduling.remove(next)
            guard self.generation == gen, self.scheduledThrough == through,
                let buffers, !buffers.isEmpty
            else { return }
            self.append(buffers, chunk: next, generation: gen)
            self.ensureScheduledAhead()
        }
    }

    private func chunkBuffersPlayed(_ index: Int, generation gen: Int) {
        guard generation == gen, wantsPlayback, let script else { return }
        rendered[index] = nil
        if index >= script.chunks.count - 1 {
            articleFinished()
        } else {
            // Bookkeeping only: the next chunk is already scheduled and the
            // node just keeps playing into it.
            chunkIndex = max(chunkIndex, index + 1)
            ensureScheduledAhead()
        }
    }

    private func articleFinished() {
        // Position lands on the full duration so the position reporter
        // records the article as completed.
        wantsPlayback = false
        isPlaying = false
        currentTime = duration
        chunkIndex = 0
        stopProgressTimer()
        updateNowPlayingPosition()
        // The final syllables may still be draining through the stretcher;
        // quiesce shortly afterwards rather than cutting them off.
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.generation == gen else { return }
            self.resetSchedule()
            if self.engine.isRunning { self.engine.pause() }
        }
    }

    private func resetSchedule() {
        if engine.isRunning { playerNode.stop() }
        scheduledThrough = nil
        scheduling = []
        chunkStartFrames = [:]
        chunkFrames = [:]
        totalScheduledFrames = 0
    }

    /// This chunk's audio at the current speaking rate — from the cache when
    /// an earlier prefetch already paid for it.
    private func renderedChunk(_ index: Int) async -> [AVAudioPCMBuffer]? {
        if renderedAtRate != playbackRate {
            rendered = [:]
            renderedAtRate = playbackRate
        }
        if let cached = rendered[index] { return cached }
        guard let script, index < script.chunks.count else { return nil }
        let buffers = await render(text: script.chunks[index].text)
        guard renderedAtRate == playbackRate else { return nil }  // rate moved mid-render
        rendered[index] = buffers
        // Keep the cache to a working set; a long article should not
        // accumulate its whole audio in memory.
        rendered = rendered.filter { abs($0.key - chunkIndex) <= 2 }
        return buffers
    }

    /// Synthesises one chunk to PCM buffers at the current speaking rate —
    /// the voice genuinely talks faster, it is never stretched afterwards.
    private func render(text: String) async -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = Self.utteranceRate(for: playbackRate)
        let audio = await withCheckedContinuation {
            (continuation: CheckedContinuation<RenderedAudio, Never>) in
            let collector = RenderCollector(continuation: continuation)
            // @Sendable because the synthesiser invokes this on its own
            // queue; a main-actor closure would trap when it does.
            synthesizer.write(utterance) { @Sendable buffer in
                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    collector.append(RenderedAudio(buffers: [pcm]))
                } else {
                    // The empty buffer is the synthesiser's end marker.
                    collector.finish()
                }
            }
        }
        return audio.buffers
    }

    private func startEngine(with format: AVAudioFormat) -> Bool {
        if engineFormat != format {
            engine.connect(playerNode, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            engineFormat = format
        }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                return false
            }
        }
        return true
    }

    // MARK: - Progress

    /// The player node restarts its clock at every stop(), so its sample time
    /// is exactly "content seconds into the current chunk" — and because the
    /// node sits before the time-stretch, this stays true at any rate.
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.progressTicked() }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func progressTicked() {
        guard isPlaying, !isScrubbing, let script,
            let nodeTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return }
        let playedFrames = playerTime.sampleTime
        // Which scheduled chunk is actually sounding right now? The node's
        // sample clock runs continuously across the gapless schedule, so the
        // answer is a lookup, not a guess from callbacks.
        guard
            let (index, startFrame) = chunkStartFrames
                .filter({ $0.value <= playedFrames })
                .max(by: { $0.value < $1.value }),
            index < script.chunks.count,
            let frames = chunkFrames[index], frames > 0
        else { return }
        chunkIndex = index
        let chunk = script.chunks[index]
        // Real elapsed audio mapped onto the estimated timeline, so saved
        // positions stay comparable across sessions.
        let fraction = min(Double(playedFrames - startFrame) / Double(frames), 1)
        currentTime = chunk.start + chunk.duration * fraction
        updateNowPlayingPosition()
        ensureScheduledAhead()
    }

    // MARK: - Lock screen

    private func publishNowPlaying(_ episode: Episode) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        publishArtwork(for: episode)
    }

    private func publishArtwork(for episode: Episode) {
        guard let url = episode.imageURL else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                let image = UIImage(data: data)
            else { return }
            guard self?.currentEpisode?.id == episode.id else { return }
            // @Sendable, not main-actor: MediaPlayer renders the artwork on
            // its own queue, and a main-actor closure traps when it does.
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func updateNowPlayingPosition() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// PCM buffers boxed for a queue hop. @unchecked Sendable is honest here:
/// each hop hands the buffers over completely — the sender keeps no
/// reference — the compiler just cannot see that.
private struct RenderedAudio: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
}

/// Accumulates the synthesiser's rendered buffers and resumes the waiting
/// continuation exactly once, on the empty end-marker buffer. A class rather
/// than captured vars: the write callback arrives on the synthesiser's own
/// queue, so the state needs a lock, not an actor.
private final class RenderCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<RenderedAudio, Never>?

    init(continuation: CheckedContinuation<RenderedAudio, Never>) {
        self.continuation = continuation
    }

    func append(_ piece: RenderedAudio) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(contentsOf: piece.buffers)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        let finished = collected
        collected = []
        continuation?.resume(returning: RenderedAudio(buffers: finished))
        continuation = nil
    }
}
