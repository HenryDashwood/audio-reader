import Foundation

/// Builds the Kokoro engine, if this build has one.
///
/// The MLX engine only exists when the `kokoro-ios` package has been added to
/// the project and the app is running on a real device. The simulator can link
/// modern MLX releases, but it has no Metal GPU capable of running inference.
/// In either unavailable case the app falls back to Apple's voices.
nonisolated enum KokoroEngines {
    /// The one engine in the process.
    ///
    /// Shared rather than made on demand because the weights are hundreds of
    /// megabytes: a second copy behind the Settings picker would be enough to
    /// have the reader killed for memory on a 4GB phone. Nil when the package
    /// is absent or the model files are not on the device, which are the two
    /// ordinary reasons to stay on the system voice.
    static let shared: KokoroRendering? = make()

    private static func make() -> KokoroRendering? {
        #if canImport(KokoroSwift) && !targetEnvironment(simulator)
            guard let model = KokoroModelStore.modelURL,
                let voices = KokoroModelStore.voicesURL
            else { return nil }
            return MLXKokoroEngine(modelURL: model, voicesURL: voices)
        #else
            return nil
        #endif
    }

    /// Whether choosing a Kokoro voice could do anything on this build.
    static var isAvailable: Bool {
        #if canImport(KokoroSwift) && !targetEnvironment(simulator)
            return KokoroModelStore.isInstalled
        #else
            return false
        #endif
    }
}
