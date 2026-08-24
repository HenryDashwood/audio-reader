import BackgroundAssets
import Foundation
import System

/// Where the Kokoro weights and voices live.
///
/// Two files, neither of them in the app bundle: `kokoro-v1_0.safetensors`
/// (~330MB) and `voices.npz`. Production installs read them from an on-demand
/// Background Assets pack. Application Support remains a developer escape
/// hatch for pushing a locally built model onto a test phone.
nonisolated enum KokoroModelStore {
    static let assetPackID = "hearful-kokoro-english-v1"
    static let modelFileName = "kokoro-v1_0"
    static let modelFileExtension = "safetensors"
    static let voicesFileName = "voices"
    static let voicesFileExtension = "npz"

    /// Where a developer-pushed copy can go during local testing.
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

    /// Whether the optional natural-voice download is ready to use.
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
        let path = FilePath("Kokoro/\(name).\(fileExtension)")
        guard let asset = try? AssetPackManager.shared.url(for: path),
            FileManager.default.fileExists(atPath: asset.path)
        else { return nil }
        return asset
    }
}
