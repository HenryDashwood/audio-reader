import Foundation

/// Builds the Kokoro engine, if this build has one.
///
/// The MLX engine only exists when the `kokoro-ios` package has been added to
/// the project — the whole file is behind `#if canImport(KokoroSwift)`. That
/// keeps a checkout without the package compiling and running exactly as it
/// does today, on Apple's voices, rather than failing to build.
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
        #if canImport(KokoroSwift)
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
        #if canImport(KokoroSwift)
            return KokoroModelStore.isInstalled
        #else
            return false
        #endif
    }
}
