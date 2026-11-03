import Foundation

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

    /// The folder holding the voice's models, text files and speakers.
    ///
    /// For now only a Debug build has one: `HEARFUL_NATURAL_VOICE_DIR` names a
    /// folder on the Mac, which the simulator can read (launch with
    /// `SIMCTL_CHILD_HEARFUL_NATURAL_VOICE_DIR`). The download comes next.
    static var folder: URL? {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["HEARFUL_NATURAL_VOICE_DIR"], !path.isEmpty {
                let url = URL(filePath: path, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: url.appending(path: "vocab.json").path) { return url }
            }
        #endif
        return nil
    }

    /// The speakers in the folder.
    static func voices(in folder: URL) -> [NaturalVoice] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "voices").path)) ?? []
        return names.filter { $0.hasSuffix(".bin") }.map { NaturalVoice(id: String($0.dropLast(4))) }
            .sorted { ($0.isBritish ? 0 : 1, $0.id) < ($1.isBritish ? 0 : 1, $1.id) }
    }

    /// The speaker reading articles, if the voice is here and one was chosen.
    /// A Debug launch can choose with `HEARFUL_NATURAL_VOICE`, e.g. `bf_emma`.
    static func selected(defaults: UserDefaults = .standard) -> (folder: URL, voice: NaturalVoice)? {
        guard let folder else { return nil }
        var id = defaults.string(forKey: selectionKey)
        #if DEBUG
            if let chosen = ProcessInfo.processInfo.environment["HEARFUL_NATURAL_VOICE"], !chosen.isEmpty { id = chosen }
        #endif
        guard let id, let voice = voices(in: folder).first(where: { $0.id == id }) else { return nil }
        return (folder, voice)
    }
}
