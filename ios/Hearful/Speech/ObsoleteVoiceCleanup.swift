import Foundation

/// Removes writable model caches and saved selections left by earlier
/// experimental voice builds. The cleanup is intentionally best-effort and
/// contains no synthesis or download code.
nonisolated enum ObsoleteVoiceCleanup {
    private static let applicationSupportDirectories = [
        "Kokoro",
        "Supertonic",
        "SupertonicCoreMLCache",
        "PocketTTS",
        "PocketTTS-ONNX",
        "Piper-VITS",
    ]

    static func remove() async {
        UserDefaults.standard.removeObject(forKey: "HearfulNaturalVoice")
        let directoryNames = applicationSupportDirectories
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                defer { continuation.resume() }
                guard let root = try? FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                ) else { return }

                for name in directoryNames {
                    let directory = root.appendingPathComponent(name, isDirectory: true)
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
    }
}
