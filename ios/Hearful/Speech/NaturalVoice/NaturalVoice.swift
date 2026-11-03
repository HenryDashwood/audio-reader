import BackgroundAssets
import Foundation
import System

/// One of the downloadable voice's speakers, by Kokoro's name for it.
nonisolated struct NaturalVoice: Sendable, Hashable, Identifiable {
    let id: String

    /// Kokoro's names start with the accent: "b" British, "a" American.
    var isBritish: Bool { id.hasPrefix("b") }

    var label: String {
        let name = id.split(separator: "_").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? id
        return "\(name) (\(isBritish ? "British" : "American"))"
    }
}

/// Where the downloadable voice is, and which of its speakers reads articles.
nonisolated enum NaturalVoiceStore {
    /// Not "HearfulNaturalVoice", which ObsoleteVoiceCleanup removes on launch.
    static let selectionKey = "HearfulDownloadedVoice"

    /// The on-demand, Apple-hosted asset pack the voice arrives in. Its files sit under `NaturalVoice/`.
    static let assetPackID = "hearful-natural-voice-v1"

    /// What a usable voice folder holds, beside at least one speaker in `voices/`.
    static let requiredFiles = [
        "vocab.json", "voice.json", "tokens.mlmodelc", "prosody.mlmodelc", "source.mlmodelc", "body.mlmodelc",
        "tagger.bin", "tagger_labels.txt", "us_gold.json", "us_silver.json", "gb_gold.json", "gb_silver.json",
        "lexicon_us.json", "lexicon_gb.json", "g2p_us.g2p", "g2p_gb.g2p",
    ]

    /// The folder holding the voice's models, text files and speakers: the downloaded asset pack's.
    ///
    /// A Debug build can name a folder on the Mac instead with `HEARFUL_NATURAL_VOICE_DIR`, which the
    /// simulator can read (launch with `SIMCTL_CHILD_HEARFUL_NATURAL_VOICE_DIR`).
    static var folder: URL? {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["HEARFUL_NATURAL_VOICE_DIR"], !path.isEmpty {
                let url = URL(filePath: path, directoryHint: .isDirectory)
                if isUsable(url) { return url }
            }
        #endif
        // Background Assets lays a file out on disk only once its URL is asked for, so ask for every one: checking
        // the folder after asking for vocab.json alone finds nothing else in it.
        let urls = (requiredFiles + ["voices"]).map { try? AssetPackManager.shared.url(for: FilePath("NaturalVoice/\($0)")) }
        guard let url = urls.first??.deletingLastPathComponent(),
            urls.allSatisfy({ $0?.deletingLastPathComponent() == url })
        else { return nil }
        return isUsable(url) ? url : nil
    }

    /// `name` in the voice's folder if it's there. From the asset pack, asks Background Assets first, which is what
    /// puts a file on disk.
    static func file(_ name: String, in folder: URL) -> URL? {
        _ = try? AssetPackManager.shared.url(for: FilePath("NaturalVoice/\(name)"))
        let url = folder.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether `folder` has everything the engine reads, so a partial or damaged download is never offered.
    static func isUsable(_ folder: URL) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
            && !voices(in: folder).isEmpty
    }

    /// The speakers in the folder.
    static func voices(in folder: URL) -> [NaturalVoice] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "voices").path)) ?? []
        return names.filter { $0.hasSuffix(".bin") }.map { NaturalVoice(id: String($0.dropLast(4))) }
            .sorted { ($0.isBritish ? 0 : 1, $0.id) < ($1.isBritish ? 0 : 1, $1.id) }
    }

    /// Which speaker reads articles; nil for Apple's voice.
    static func select(_ voice: NaturalVoice?, defaults: UserDefaults = .standard) {
        defaults.set(voice?.id, forKey: selectionKey)
    }

    /// The speaker reading articles, if the voice is here and one was chosen.
    /// A Debug launch can choose with `HEARFUL_NATURAL_VOICE`, e.g. `bf_emma`.
    static func selected(defaults: UserDefaults = .standard) -> (folder: URL, voice: NaturalVoice)? {
        guard let id = selectedID(defaults: defaults), let folder,
            let voice = voices(in: folder).first(where: { $0.id == id })
        else { return nil }
        return (folder, voice)
    }

    /// The chosen speaker's name, whether or not the voice is still here.
    static func selectedID(defaults: UserDefaults = .standard) -> String? {
        #if DEBUG
            if let chosen = ProcessInfo.processInfo.environment["HEARFUL_NATURAL_VOICE"], !chosen.isEmpty { return chosen }
        #endif
        return defaults.string(forKey: selectionKey)
    }
}
