import Foundation

/// Where the Kokoro weights and voices live.
///
/// Two files, neither of them in the repository: `kokoro-v1_0.safetensors`
/// (~330MB) and `voices.npz`. For the prototype they are dragged into the
/// Xcode project and ride along in the app bundle; Application Support is
/// checked first so a downloaded copy can shadow the bundled one later
/// without any of the calling code changing. `docs/kokoro-prototype.md` has
/// the fetching and converting steps.
nonisolated enum KokoroModelStore {
    static let modelFileName = "kokoro-v1_0"
    static let modelFileExtension = "safetensors"
    static let voicesFileName = "voices"
    static let voicesFileExtension = "npz"

    /// Where a downloaded copy would go. Not created here — nothing writes to
    /// it yet.
    static var downloadDirectory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        .appendingPathComponent("Kokoro", isDirectory: true)
    }

    static var modelURL: URL? {
        locate(modelFileName, modelFileExtension)
    }

    static var voicesURL: URL? {
        locate(voicesFileName, voicesFileExtension)
    }

    /// Whether the voice can be offered at all. False on a build where nobody
    /// has added the files, which is the normal state of a fresh checkout.
    static var isInstalled: Bool {
        modelURL != nil && voicesURL != nil
    }

    private static func locate(_ name: String, _ fileExtension: String) -> URL? {
        if let downloaded = downloadDirectory?
            .appendingPathComponent(name)
            .appendingPathExtension(fileExtension),
            FileManager.default.fileExists(atPath: downloaded.path)
        {
            return downloaded
        }
        return Bundle.main.url(forResource: name, withExtension: fileExtension)
    }
}
