import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// The word the system voice is about to speak, in the complete plain-text
/// article. AVSpeechSynthesizer and NSString both count UTF-16 code units, so
/// the range can travel from the voice to WebKit without lossy conversion.
nonisolated struct ArticleSpokenLocation: Equatable, Sendable {
    let episodeID: Int
    let rangeInArticle: NSRange
}

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
    /// Exact text position for the on-screen reading marker. Nil before an
    /// article has started, and whenever article speech is no longer active.
    @Published private(set) var spokenLocation: ArticleSpokenLocation?

    private var synthesizer: SpeechSynthesizing
    private let api: HearfulAPIProtocol
    private let cache: OfflineCache
    private var script: ArticleScript?
    private var chunkIndex = 0
    /// True once she asked for sound: speech starts as soon as text arrives.
    private var wantsPlayback = false
    /// Identity of the utterance now speaking; delegate callbacks for
    /// anything else (cancelled by a seek, a rate change, a new article)
    /// are stale and ignored.
    private var currentUtterance: ObjectIdentifier?
    private var loadTask: Task<Void, Never>?
    /// Mirrors the backend's teaser boundary. A linked saved copy below this
    /// size may have come from the old failed-extraction fallback, so give the
    /// server one chance to replace it before speaking it.
    private static let likelyTeaserCharacterLimit = 600
    /// Sounded when an article is read to the end. Injectable for tests.
    var feedback: FeedbackPlaying = Feedback.shared
    /// Announces that the article has been read to the end, for the
    /// coordinator to act on.
    let finished = PassthroughSubject<Void, Never>()

    init(
        api: HearfulAPIProtocol = HearfulAPI(),
        cache: OfflineCache = .shared,
        synthesizer: SpeechSynthesizing = SpeechSynthesizers.make()
    ) {
        self.api = api
        self.cache = cache
        self.synthesizer = synthesizer
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
    /// Preloading the text also rebuilds its estimated timeline, so the
    /// scrubber can show the saved position and time remaining before she
    /// presses Play.
    func restore(_ episode: Episode) {
        guard currentEpisode == nil else { return }
        load(episode, andPlay: false)
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
        if wantsPlayback {
            // Deliberately not set here as well: speakCurrentChunk lands
            // currentTime on this chunk's start itself, and setting it twice
            // publishes the same position to everything downstream twice.
            speakCurrentChunk()
        } else {
            currentTime = script.chunks[index].start
            cancelSpeech()
            publishChunkStart(index, in: script)
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

        loadTask = Task { [weak self, api, cache] in
            // ArticleView has already saved this exact payload after showing
            // it. Reading must use the same copy first: asking the server for
            // text we can see makes a brief outage turn a readable article
            // into a spoken network error.
            let saved = cache.load(
                EpisodeText.self,
                for: .articleText(episodeID: episode.id)
            )
            let savedMayBeFeedTeaser =
                episode.link != nil
                && (saved?.text.count ?? Self.likelyTeaserCharacterLimit)
                    < Self.likelyTeaserCharacterLimit
            if let saved, !saved.text.isEmpty, !savedMayBeFeedTeaser {
                guard let self, !Task.isCancelled, self.currentEpisode?.id == episode.id else {
                    return
                }
                self.scriptLoaded(ArticleScript(text: saved.text))
                return
            }

            do {
                let article = try await api.articleText(episodeID: episode.id)
                guard let self, !Task.isCancelled, self.currentEpisode?.id == episode.id else {
                    return
                }
                cache.save(article, for: .articleText(episodeID: episode.id))
                self.scriptLoaded(ArticleScript(text: article.text))
            } catch {
                guard let self, !Task.isCancelled, self.currentEpisode?.id == episode.id else {
                    return
                }
                // A suspicious short copy is still better than silence when
                // she is genuinely offline. Keep it as a fallback, but do not
                // use it to conceal an expired sign-in session.
                if (error as? APIError)?.isAuthFailure != true,
                    let saved,
                    !saved.text.isEmpty
                {
                    self.scriptLoaded(ArticleScript(text: saved.text))
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
        let shouldSpeak = wantsPlayback
        wantsPlayback = false
        isPlaying = false
        // A launch restore and prepare() are silent preloads. If the network
        // is unavailable, leave the saved position waiting and try again when
        // she actually presses Play rather than announcing an error she did
        // not trigger.
        guard shouldSpeak else { return }
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
        // Keep the marker present while one utterance replaces another; the
        // exact first word follows with the synthesiser's next callback.
        cancelSpeech(clearingLocation: false)
        currentTime = script.chunks[chunkIndex].start
        publishChunkStart(chunkIndex, in: script)
        let utterance = AVSpeechUtterance(string: script.chunks[chunkIndex].text)
        utterance.voice = SpeechVoice.current
        utterance.rate = Self.utteranceRate(for: playbackRate)
        utterance.postUtteranceDelay = 0.15
        currentUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
        isPlaying = true
        updateNowPlayingPosition()
    }

    /// Stops the synthesiser without letting stale delegate callbacks act:
    /// only didFinish for the current utterance advances playback, and a
    /// deliberate stop arrives as didCancel, which is ignored.
    private func cancelSpeech(clearingLocation: Bool = true) {
        currentUtterance = nil
        if clearingLocation { spokenLocation = nil }
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - SpeechSynthesizingDelegate

    func speechFinished(_ utterance: UtteranceID) {
        chunkFinished(utterance)
    }

    func speechProgressed(to range: NSRange, of utterance: UtteranceID) {
        progressed(to: range, of: utterance)
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

    private func progressed(to range: NSRange, of speaking: ObjectIdentifier) {
        guard speaking == currentUtterance, isPlaying, !isScrubbing,
            let episode = currentEpisode, let script, chunkIndex < script.chunks.count
        else { return }
        let chunk = script.chunks[chunkIndex]
        let utteranceLength = (chunk.text as NSString).length
        let location = min(max(range.location, 0), utteranceLength)
        let available = max(utteranceLength - location, 0)
        let length = min(max(range.length, 0), available)
        spokenLocation = ArticleSpokenLocation(
            episodeID: episode.id,
            rangeInArticle: NSRange(
                location: chunk.textRange.location + location,
                length: length))
        let fraction = Double(location) / Double(max(utteranceLength, 1))
        currentTime = chunk.start + chunk.duration * min(fraction, 1)
        updateNowPlayingPosition()
    }

    /// A seek and a chunk transition have a meaningful position before the
    /// voice begins its next word. Publishing the zero-width start keeps the
    /// marker from lingering on the old line during that short gap.
    private func publishChunkStart(_ index: Int, in script: ArticleScript) {
        guard let episode = currentEpisode, script.chunks.indices.contains(index) else { return }
        spokenLocation = ArticleSpokenLocation(
            episodeID: episode.id,
            rangeInArticle: NSRange(location: script.chunks[index].textRange.location, length: 0))
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
