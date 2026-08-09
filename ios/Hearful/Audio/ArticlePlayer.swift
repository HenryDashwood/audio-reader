import AVFoundation
import MediaPlayer
import UIKit

/// Reads articles aloud with the on-device voice, presenting itself to the
/// rest of the app exactly like audio playback: an (estimated) timeline in
/// seconds, so the scrubber, skip buttons, saved positions and lock screen
/// behave the same as for podcast audio.
///
/// If article audio is ever rendered server-side (ElevenLabs et al.), those
/// items arrive as ordinary episodes with an audio_url and never reach this
/// class — nothing here needs to change.
@MainActor
final class ArticlePlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    /// One player for the whole app, for the same reason as AudioPlayer: Siri
    /// intents run without any UI.
    static let shared = ArticlePlayer()

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var isScrubbing = false
    @Published private(set) var playbackRate: Float = 1.0

    private let synthesizer = AVSpeechSynthesizer()
    private let api: HearfulAPIProtocol
    private var script: ArticleScript?
    private var chunkIndex = 0
    /// True once she asked for sound: speech starts as soon as text arrives.
    private var wantsPlayback = false
    private var loadTask: Task<Void, Never>?

    init(api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)) {
        self.api = api
        super.init()
        synthesizer.delegate = self
        // Same stored preference as AudioPlayer: her speed is her speed,
        // whether the thing playing is streamed or spoken.
        let stored = UserDefaults.standard.float(forKey: "HearfulPlaybackRate")
        playbackRate = stored > 0 ? stored : 1.0
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
            speakCurrentChunk()
            return
        }
        load(episode, andPlay: true)
    }

    func pause() {
        wantsPlayback = false
        if synthesizer.isSpeaking {
            // .word, not .immediate: stopping mid-word sounds like a fault.
            synthesizer.pauseSpeaking(at: .word)
        }
        isPlaying = false
        updateNowPlayingPosition()
    }

    func resume() {
        guard let episode = currentEpisode else { return }
        try? AudioSession.configureForPlayback()
        wantsPlayback = true
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPlaying = true
            updateNowPlayingPosition()
        } else if script != nil {
            speakCurrentChunk()
        } else {
            // Restored at launch: the text has not been fetched yet.
            load(episode, andPlay: true)
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
            speakCurrentChunk()
        } else {
            cancelUtterance()
            updateNowPlayingPosition()
        }
    }

    func setPlaybackRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 3.0)
        playbackRate = clamped
        // An utterance's rate is fixed once queued; restart the current chunk
        // at the new speed. Chunks are short, so the rewind is slight.
        if wantsPlayback, script != nil {
            speakCurrentChunk()
        }
        updateNowPlayingPosition()
    }

    /// Called when audio playback takes over: stop making sound, keep state.
    func deactivate() {
        if isPlaying || synthesizer.isPaused {
            pause()
            cancelUtterance()
        }
    }

    // MARK: - Loading

    private func load(_ episode: Episode, andPlay: Bool) {
        loadTask?.cancel()
        cancelUtterance()
        isPlaying = false
        currentEpisode = episode
        script = nil
        chunkIndex = 0
        wantsPlayback = andPlay
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
            speakCurrentChunk()
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
        synthesizer.speak(utterance)
    }

    // MARK: - Speaking

    private func speakCurrentChunk() {
        guard let script, chunkIndex < script.chunks.count else { return }
        cancelUtterance()
        currentTime = script.chunks[chunkIndex].start
        let utterance = AVSpeechUtterance(string: script.chunks[chunkIndex].text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        // The default utterance rate is normal speech; scale from there and
        // clamp into what the synthesiser accepts.
        utterance.rate = min(
            max(
                AVSpeechUtteranceDefaultSpeechRate * playbackRate,
                AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate)
        utterance.postUtteranceDelay = 0.15
        synthesizer.speak(utterance)
        isPlaying = true
        updateNowPlayingPosition()
    }

    /// Stops the synthesiser. Only didFinish advances chunks — a deliberate
    /// stop arrives as didCancel, which is ignored — so cancelling never
    /// double-advances playback.
    private func cancelUtterance() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.chunkFinished() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let fraction = Double(characterRange.location) / Double(max(utterance.speechString.count, 1))
        Task { @MainActor in self.progressed(fraction: fraction) }
    }

    private func chunkFinished() {
        guard wantsPlayback, let script else { return }
        chunkIndex += 1
        if chunkIndex < script.chunks.count {
            speakCurrentChunk()
        } else {
            // The end of the article. Position lands on the full duration so
            // the position reporter records it as completed.
            wantsPlayback = false
            isPlaying = false
            currentTime = duration
            chunkIndex = 0
            updateNowPlayingPosition()
        }
    }

    private func progressed(fraction: Double) {
        guard let script, chunkIndex < script.chunks.count, isPlaying, !isScrubbing else { return }
        let chunk = script.chunks[chunkIndex]
        currentTime = chunk.start + chunk.duration * fraction
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
