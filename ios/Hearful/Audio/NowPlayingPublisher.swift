import MediaPlayer
import UIKit

/// Owns the system card for the coordinator's active item. Individual players
/// never merge their clocks or artwork into another player's metadata.
@MainActor
final class NowPlayingPublisher {
    private let publish: ([String: Any]?) -> Void
    private var episodeID: Int?
    private var imageURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var artworkGeneration = 0
    private var info: [String: Any]?

    init(publish: @escaping ([String: Any]?) -> Void = {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = $0
    }) {
        self.publish = publish
    }

    func update(episode: Episode?, isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval, rate: Float) {
        if episodeID != episode?.id || imageURL != episode?.imageURL {
            artworkTask?.cancel()
            artworkGeneration += 1
            episodeID = episode?.id
            imageURL = episode?.imageURL
            artwork = nil
            if let imageURL { fetchArtwork(imageURL, generation: artworkGeneration) }
        }
        guard let episode else {
            if info != nil {
                info = nil
                publish(nil)
            }
            return
        }
        var next: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
        ]
        if duration > 0 { next[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { next[MPMediaItemPropertyArtwork] = artwork }
        info = next
        publish(next)
    }

    private func fetchArtwork(_ url: URL, generation: Int) {
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                !Task.isCancelled, let image = UIImage(data: data),
                let self, self.artworkGeneration == generation,
                var info = self.info
            else { return }
            // MediaPlayer renders artwork off the main actor.
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            self.artwork = artwork
            info[MPMediaItemPropertyArtwork] = artwork
            self.info = info
            self.publish(info)
        }
    }
}
