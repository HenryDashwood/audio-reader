// Opt-in prototype: build with HEARFUL_SIRI_AUDIO_FLAGS=HEARFUL_NATIVE_SIRI_AUDIO
// using Xcode 27. Keep the shipping iOS 26 shortcut routing until on-device
// Siri media routing has been validated on the final OS.
#if canImport(MediaIntents) && HEARFUL_NATIVE_SIRI_AUDIO
    import AppIntents
    import Foundation
    import MediaIntents

    @available(iOS 27.0, *)
    @AppEntity(schema: .audio.podcastEpisode)
    struct SiriPodcastEpisode {
        static let defaultQuery = SiriPodcastQuery()
        let id: Int
        var title: String
        var showName: String?
        var show: SiriPodcastShow?
        var releaseDate: Date?
        var duration: Double?
        var displayRepresentation: DisplayRepresentation {
            DisplayRepresentation(title: "\(title)", subtitle: "\(showName ?? "Podcast")")
        }
        init(_ episode: Episode) {
            id = episode.id
            title = episode.title
            showName = episode.feedTitle
            releaseDate = episode.publishedAt
            duration = episode.durationSeconds.map(Double.init)
        }
    }

    @available(iOS 27.0, *)
    struct SiriPodcastQuery: EntityStringQuery {
        @MainActor
        func entities(for identifiers: [Int]) async throws -> [SiriPodcastEpisode] {
            try await ShortcutLibrary.shared.episodes(ids: identifiers).filter { $0.audioURL != nil }.map(
                SiriPodcastEpisode.init)
        }
        @MainActor
        func entities(matching string: String) async throws -> [SiriPodcastEpisode] {
            try await ShortcutLibrary.shared.find(string).filter { $0.audioURL != nil }.map(
                SiriPodcastEpisode.init)
        }
    }

    @available(iOS 27.0, *)
    @AppEntity(schema: .audio.podcastShow)
    struct SiriPodcastShow {
        static let defaultQuery = SiriPodcastShowQuery()
        let id: Int
        var title: String
        var showDescription: String?
        var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
        init(_ show: Show) {
            id = show.id
            title = show.title
            showDescription = show.description
        }
    }

    @available(iOS 27.0, *)
    struct SiriPodcastShowQuery: EntityStringQuery {
        @MainActor
        func entities(for identifiers: [Int]) async throws -> [SiriPodcastShow] {
            try await ShortcutLibrary.shared.shows().filter {
                identifiers.contains($0.id) && $0.isArticleFeed != true
            }.map(SiriPodcastShow.init)
        }
        @MainActor
        func entities(matching string: String) async throws -> [SiriPodcastShow] {
            try await ShortcutLibrary.shared.shows().filter {
                $0.isArticleFeed != true && $0.title.localizedStandardContains(string)
            }.map(SiriPodcastShow.init)
        }
    }

    @available(iOS 27.0, *)
    @UnionValue
    enum SiriAudioItem {
        case episode(SiriPodcastEpisode)
        case show(SiriPodcastShow)
    }

    @available(iOS 27.0, *)
    struct SiriAudioQuery: IntentValueQuery {
        @MainActor
        func values(for input: AudioSearch) async throws -> [SiriAudioItem] {
            switch input.criteria {
            case .searchQuery(let query):
                let episodes = try await SiriPodcastQuery().entities(matching: query).map(
                    SiriAudioItem.episode)
                let shows = try await SiriPodcastShowQuery().entities(matching: query).map(SiriAudioItem.show)
                return episodes + shows
            case .unspecified:
                if let current = try? await ShortcutPlayback.resolve(id: nil), current.audioURL != nil {
                    return [.episode(SiriPodcastEpisode(current))]
                }
                return try await SiriPodcastQuery().entities(matching: "").map(SiriAudioItem.episode)
            case .url(let urls):
                // Resolve known library URLs only. Never turn Siri's discovery
                // query into a subscription or arbitrary media download.
                let items = try await ShortcutLibrary.shared.find("")
                return items.filter {
                    $0.audioURL != nil && (urls.contains($0.audioURL!) || $0.link.map(urls.contains) == true)
                }
                .map { .episode(SiriPodcastEpisode($0)) }
            @unknown default: return []
            }
        }
    }

    @available(iOS 27.0, *)
    @AppEnum(schema: .audio.playbackAttributes)
    enum SiriPlaybackAttributes: String {
        case shuffle, `repeat`
        static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
            .shuffle: "Shuffle", .repeat: "Repeat",
        ]
    }

    @available(iOS 27.0, *)
    @AppEnum(schema: .audio.queueInsertionLocation)
    enum SiriQueueLocation: String {
        case next, tail
        static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.next: "Next", .tail: "Tail"]
    }

    @available(iOS 27.0, *)
    @AppEntity(schema: .audio.warmupAudioQueueResult)
    struct SiriWarmupResult: TransientAppEntity {
        init() {}
        var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Audio preparation") }
    }

    @available(iOS 27.0, *)
    @AppIntent(schema: .audio.playAudio)
    struct PlaySiriPodcastIntent: AudioPlaybackIntent {
        var audioEntity: SiriAudioItem
        var playbackAttributes: Set<SiriPlaybackAttributes>
        var warmupAudioQueueResult: SiriWarmupResult?
        var queueLocation: SiriQueueLocation?
        static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
        @MainActor
        func perform() async throws -> some IntentResult {
            guard playbackAttributes.isEmpty, queueLocation == nil, warmupAudioQueueResult == nil else {
                throw ShortcutFailure(
                    message:
                        "Magpie plays one item at a time. Queuing, shuffle, and repeat are not available.")
            }
            let chosen: Episode
            switch audioEntity {
            case .episode(let episode): chosen = try await ShortcutPlayback.resolve(id: episode.id)
            case .show(let show):
                guard
                    let episode = try await ShortcutLibrary.shared.find("", showID: show.id).first(where: {
                        $0.audioURL != nil
                    })
                else {
                    throw ShortcutFailure(message: "That show has no podcast audio available.")
                }
                chosen = try await ShortcutPlayback.resolve(id: episode.id)
            }
            try await ShortcutPlayback.start(chosen) {
                try await continueInForeground("Opening Magpie to start listening.")
            }
            return .result()
        }
    }
#endif
