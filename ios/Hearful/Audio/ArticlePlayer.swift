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
    /// The chunk currently scheduled on the player node, if any — what lets
    /// resume() distinguish "continue" from "start this chunk over".
    private var scheduledIndex: Int?
    /// True once she asked for sound: speech starts as soon as text arrives.
    private var wantsPlayback = false
    /// Bumped whenever playback restarts somewhere else (seek, new episode),
    /// so stale render tasks and buffer-completion callbacks are ignored.
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var progressTimer: Timer?
    /// Rendered chunks, kept one ahead so transitions have no synthesis gap.
    private var rendered: [Int: [AVAudioPCMBuffer]] = [:]

    init(api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)) {
        self.api = api
        super.init()
        engine.attach(playerNode)
        engine.attach(timePitch)
        // Same stored preference as AudioPlayer: her speed is her speed,
        // whether the thing playing is streamed or spoken.
        let stored = UserDefaults.standard.float(forKey: "HearfulPlaybackRate")
        playbackRate = stored > 0 ? stored : 1.0
        timePitch.rate = playbackRate
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
        } else if scheduledIndex == chunkIndex {
            // Paused mid-chunk: carry on from the same word.
            if !engine.isRunning { try? engine.start() }
            playerNode.play()
            isPlaying = true
            startProgressTimer()
            updateNowPlayingPosition()
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
            if engine.isRunning { playerNode.stop() }
            scheduledIndex = nil
            updateNowPlayingPosition()
        }
    }

    /// Instant and clean at any speed: the time-stretch sits after the
    /// synthesiser, so the voice itself is never re-rendered.
    func setPlaybackRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 3.0)
        playbackRate = clamped
        timePitch.rate = clamped
        updateNowPlayingPosition()
    }

    /// Called when audio playback takes over: stop making sound, keep state.
    func deactivate() {
        wantsPlayback = false
        generation += 1
        if engine.isRunning {
            playerNode.stop()
            engine.pause()
        }
        scheduledIndex = nil
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
    private func startPlayback(at index: Int) {
        guard let script, index < script.chunks.count else { return }
        generation += 1
        let gen = generation
        if engine.isRunning { playerNode.stop() }
        scheduledIndex = nil
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
            self.schedule(buffers, forChunk: index, generation: gen)
        }
    }

    private func schedule(_ buffers: [AVAudioPCMBuffer], forChunk index: Int, generation gen: Int) {
        guard startEngine(with: buffers[0].format) else {
            loadFailed(with: APIError(underlying: "audio engine would not start"))
            return
        }
        // With the engine guaranteed running, stop() reliably clears anything
        // stale — including buffers left scheduled while the engine slept.
        playerNode.stop()
        for (position, buffer) in buffers.enumerated() {
            if position == buffers.count - 1 {
                // .dataPlayedBack: fires when the audio has actually sounded,
                // not merely been consumed — the right moment to move on.
                playerNode.scheduleBuffer(
                    buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor in self?.chunkPlayed(index, generation: gen) }
                }
            } else {
                playerNode.scheduleBuffer(buffer)
            }
        }
        scheduledIndex = index
        playerNode.play()
        isPlaying = true
        startProgressTimer()
        updateNowPlayingPosition()
        prefetch(index + 1)
    }

    private func chunkPlayed(_ index: Int, generation gen: Int) {
        guard generation == gen, wantsPlayback, let script else { return }
        rendered[index] = nil
        let next = index + 1
        if next < script.chunks.count {
            chunkIndex = next
            startPlayback(at: next)
        } else {
            // The end of the article. Position lands on the full duration so
            // the position reporter records it as completed.
            wantsPlayback = false
            isPlaying = false
            currentTime = duration
            chunkIndex = 0
            scheduledIndex = nil
            playerNode.stop()
            stopProgressTimer()
            updateNowPlayingPosition()
        }
    }

    /// This chunk's audio, rendered at 1× — from the prefetch cache when the
    /// previous chunk's playback already paid for it.
    private func renderedChunk(_ index: Int) async -> [AVAudioPCMBuffer]? {
        if let cached = rendered[index] { return cached }
        guard let script, index < script.chunks.count else { return nil }
        let buffers = await render(text: script.chunks[index].text)
        rendered[index] = buffers
        return buffers
    }

    private func prefetch(_ index: Int) {
        guard let script, index < script.chunks.count, rendered[index] == nil else { return }
        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            let buffers = await self.render(text: script.chunks[index].text)
            guard self.generation == gen else { return }
            self.rendered[index] = buffers
            // Keep the cache to a working set; a long article should not
            // accumulate its whole audio in memory.
            self.rendered = self.rendered.filter { abs($0.key - self.chunkIndex) <= 2 }
        }
    }

    /// Synthesises one chunk to PCM buffers at normal speed. The utterance
    /// rate is always the default: speed is timePitch's job.
    private func render(text: String) async -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
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
        guard isPlaying, !isScrubbing, let script, chunkIndex < script.chunks.count,
            let nodeTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        let chunk = script.chunks[chunkIndex]
        // Real elapsed audio mapped onto the estimated timeline, so saved
        // positions stay comparable across sessions.
        let renderedSeconds = rendered[chunkIndex].map(Self.seconds(of:))
        let fraction = renderedSeconds.map { min(played / max($0, 0.1), 1) } ?? 0
        currentTime = chunk.start + chunk.duration * fraction
        updateNowPlayingPosition()
    }

    private nonisolated static func seconds(of buffers: [AVAudioPCMBuffer]) -> Double {
        buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
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
