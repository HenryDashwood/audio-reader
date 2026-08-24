import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Reads articles aloud with the on-device voice, presenting itself to the
/// rest of the app exactly like audio playback: an (estimated) timeline in
/// seconds, so the scrubber, skip buttons, saved positions and lock screen
/// behave the same as for podcast audio.
///
/// Speech is spoken live by AVSpeechSynthesizer — the identical pipeline to
/// Speak Screen and VoiceOver, and the only one Apple's higher-quality
/// voices render cleanly. (Offline rendering via `write()` produced clipped
/// syllables with enhanced/premium voices; an earlier time-stretching design
/// needed it, but speed now comes from the synthesiser's own speaking rate,
/// so nothing does.) Chunks map speech onto the timeline and keep seeking
/// responsive; the per-word callback drives progress within a chunk.
///
/// If article audio is ever rendered server-side (ElevenLabs et al.), those
/// items arrive as ordinary episodes with an audio_url and never reach this
/// class — nothing here needs to change.
@MainActor
final class ArticlePlayer: ObservableObject, SpeechSynthesizingDelegate {
    /// One player for the whole app, for the same reason as AudioPlayer: Siri
    /// intents run without any UI.
    static let shared = ArticlePlayer()

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var isScrubbing = false
    @Published private(set) var playbackRate: Float = 1.0

    private var synthesizer: SpeechSynthesizing
    private let preferredSynthesizerFactory: @MainActor () -> SpeechSynthesizing
    private let fallbackSynthesizerFactory: @MainActor () -> SpeechSynthesizing
    private var voicePreferenceChanged = false
    /// A natural renderer that failed is not retried on every paragraph. A
    /// different article gets one fresh attempt; changing the voice retries
    /// immediately on the current article.
    private var systemFallbackEpisodeID: Int?
    private let api: HearfulAPIProtocol
    private var script: ArticleScript?
    private var chunkIndex = 0
    /// True once she asked for sound: speech starts as soon as text arrives.
    private var wantsPlayback = false
    /// Identity of the utterance now speaking; delegate callbacks for
    /// anything else (cancelled by a seek, a rate change, a new article)
    /// are stale and ignored.
    private var currentUtterance: ObjectIdentifier?
    private var loadTask: Task<Void, Never>?
    /// Sounded when an article is read to the end. Injectable for tests.
    var feedback: FeedbackPlaying = Feedback.shared
    /// Announces that the article has been read to the end, for the
    /// coordinator to act on.
    let finished = PassthroughSubject<Void, Never>()

    init(
        api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
        synthesizer: SpeechSynthesizing = SpeechSynthesizers.make(),
        preferredSynthesizerFactory: @escaping @MainActor () -> SpeechSynthesizing = {
            SpeechSynthesizers.make()
        },
        fallbackSynthesizerFactory: @escaping @MainActor () -> SpeechSynthesizing = {
            SpeechSynthesizers.makeSystemVoice()
        }
    ) {
        self.api = api
        self.synthesizer = synthesizer
        self.preferredSynthesizerFactory = preferredSynthesizerFactory
        self.fallbackSynthesizerFactory = fallbackSynthesizerFactory
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
        if let failedEpisode = systemFallbackEpisodeID, failedEpisode != episode.id {
            replaceSynthesizer(with: preferredSynthesizerFactory())
            systemFallbackEpisodeID = nil
        }
        applyChangedVoiceIfNeeded()
        if episode.id == currentEpisode?.id, script != nil {
            wantsPlayback = true
            speakCurrentChunk()
            return
        }
        load(episode, andPlay: true)
    }

    /// Settings calls this after changing the optional natural voice. Existing
    /// speech is left alone; the replacement is installed the next time the
    /// user starts or resumes an article.
    func voicePreferenceDidChange() {
        voicePreferenceChanged = true
    }

    private func applyChangedVoiceIfNeeded() {
        guard voicePreferenceChanged else { return }
        replaceSynthesizer(with: preferredSynthesizerFactory())
        voicePreferenceChanged = false
        systemFallbackEpisodeID = nil
    }

    private func replaceSynthesizer(with replacement: SpeechSynthesizing) {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = replacement
        synthesizer.delegate = self
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
        // A natural synthesiser captures its voice when it is created. If the
        // preference changed while paused, continuing the old object would
        // keep the old voice despite what Settings now says. Replacing it
        // restarts only the current chunk, at a clean word boundary.
        applyChangedVoiceIfNeeded()
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
        if wantsPlayback {
            // Deliberately not set here as well: speakCurrentChunk lands
            // currentTime on this chunk's start itself, and setting it twice
            // publishes the same position to everything downstream twice.
            speakCurrentChunk()
        } else {
            currentTime = script.chunks[index].start
            cancelSpeech()
            updateNowPlayingPosition()
        }
    }

    /// Restarts the current chunk at the new speaking rate — a small rewind,
    /// the price of the voice actually talking faster rather than being
    /// stretched (stretching is what made fast speech sound smeared).
    func setPlaybackRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 3.0)
        guard clamped != playbackRate else { return }
        playbackRate = clamped
        if wantsPlayback, script != nil {
            speakCurrentChunk()
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
        cancelSpeech()
        isPlaying = false
    }

    /// Stops and unloads, leaving nothing loaded at all. The episode is
    /// published as nil before the clock is wound back, for the reason given
    /// on AudioPlayer.clear().
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        deactivate()
        currentEpisode = nil
        script = nil
        chunkIndex = 0
        currentTime = 0
        duration = 0
    }

    // MARK: - Loading

    private func load(_ episode: Episode, andPlay: Bool) {
        loadTask?.cancel()
        deactivate()
        wantsPlayback = andPlay
        currentEpisode = episode
        script = nil
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
        utterance.voice = SpeechVoice.current
        try? AudioSession.configureForPlayback()
        currentUtterance = nil  // its delegate callbacks must not advance chunks
        synthesizer.speak(utterance)
    }

    // MARK: - Speaking

    private func speakCurrentChunk() {
        guard let script, chunkIndex < script.chunks.count else { return }
        cancelSpeech()
        currentTime = script.chunks[chunkIndex].start
        let utterance = AVSpeechUtterance(string: script.chunks[chunkIndex].text)
        utterance.voice = SpeechVoice.current
        utterance.rate = Self.utteranceRate(for: playbackRate)
        utterance.postUtteranceDelay = 0.15
        currentUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
        // Say what is coming while this chunk plays. For the system voice this
        // does nothing; for a synthesiser that has to render the audio first
        // it is the difference between chunks running together and a silence
        // at every paragraph.
        if chunkIndex + 1 < script.chunks.count {
            let next = AVSpeechUtterance(string: script.chunks[chunkIndex + 1].text)
            next.voice = utterance.voice
            next.rate = utterance.rate
            synthesizer.prepare(next)
        }
        isPlaying = true
        updateNowPlayingPosition()
    }

    /// Stops the synthesiser without letting stale delegate callbacks act:
    /// only didFinish for the current utterance advances playback, and a
    /// deliberate stop arrives as didCancel, which is ignored.
    private func cancelSpeech() {
        currentUtterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - SpeechSynthesizingDelegate

    func speechFinished(_ utterance: UtteranceID) {
        chunkFinished(utterance)
    }

    func speechFailed(_ utterance: UtteranceID) {
        guard utterance == currentUtterance, wantsPlayback else { return }
        // Keep the optional preference for a future article, but finish this
        // one with the dependable system voice. Restarting the current chunk
        // means no text is silently lost even if some of it had rendered.
        systemFallbackEpisodeID = currentEpisode?.id
        replaceSynthesizer(with: fallbackSynthesizerFactory())
        speakCurrentChunk()
    }

    func speechProgressed(toFraction fraction: Double, of utterance: UtteranceID) {
        progressed(fraction: fraction, of: utterance)
    }

    private func chunkFinished(_ finished: ObjectIdentifier) {
        guard finished == currentUtterance, wantsPlayback, let script else { return }
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
            currentUtterance = nil
            updateNowPlayingPosition()
            // The same marker a finished episode gets: an article simply
            // stopping mid-silence reads as a fault.
            feedback.play(.finished)
            // Qualified: the parameter of this method shadows the subject.
            self.finished.send()
        }
    }

    private func progressed(fraction: Double, of speaking: ObjectIdentifier) {
        guard speaking == currentUtterance, isPlaying, !isScrubbing,
            let script, chunkIndex < script.chunks.count
        else { return }
        let chunk = script.chunks[chunkIndex]
        currentTime = chunk.start + chunk.duration * min(fraction, 1)
        updateNowPlayingPosition()
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
        // Nothing loaded means nothing to say — see AudioPlayer's copy.
        guard currentEpisode != nil else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
