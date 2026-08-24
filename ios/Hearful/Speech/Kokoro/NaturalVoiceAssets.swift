import BackgroundAssets
import Combine
import Foundation

nonisolated protocol KokoroAssetInstalling: Sendable {
    var isInstalled: Bool { get async }
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
    func remove() async throws
}

nonisolated enum KokoroAssetInstallError: LocalizedError {
    case assetPackMissing
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .assetPackMissing:
            "The natural voices are not available for this version of Hearful yet."
        case .incompleteDownload:
            "The natural voice download did not contain all of the files Hearful needs."
        }
    }
}

/// Installs the large Kokoro data files without putting them in the app bundle.
///
/// The executable MLX code still ships with Hearful, but the model and voice
/// archive live in an Apple-hosted, on-demand Background Assets pack. The pack
/// is only requested after the user chooses to download it in Settings.
actor BackgroundKokoroAssetInstaller: KokoroAssetInstalling {
    private let manager = AssetPackManager.shared

    var isInstalled: Bool { KokoroModelStore.isInstalled }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let updates = manager.statusUpdates(forAssetPackWithID: KokoroModelStore.assetPackID)
        let progressTask = Task {
            for await update in updates {
                guard !Task.isCancelled else { return }
                switch update {
                case .began, .paused:
                    break
                case .downloading(_, let downloadProgress):
                    progress(downloadProgress.fractionCompleted)
                case .finished:
                    progress(1)
                    return
                case .failed:
                    return
                @unknown default:
                    break
                }
            }
        }
        defer { progressTask.cancel() }

        let pack = try await assetPack()
        #if compiler(>=6.3)
            if #available(iOS 26.4, *) {
                try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
            } else {
                try await manager.ensureLocalAvailability(of: pack)
            }
        #else
            try await manager.ensureLocalAvailability(of: pack)
        #endif
        guard KokoroModelStore.isInstalled else {
            throw KokoroAssetInstallError.incompleteDownload
        }
        progress(1)
    }

    func remove() async throws {
        try await manager.remove(assetPackWithID: KokoroModelStore.assetPackID)
    }

    private func assetPack() async throws -> AssetPack {
        #if compiler(>=6.4)
            if #available(iOS 27, *) {
                guard let pack = try await manager.manifest.assetPack(
                    withID: KokoroModelStore.assetPackID)
                else { throw KokoroAssetInstallError.assetPackMissing }
                return pack
            }
        #endif
        return try await manager.assetPack(withID: KokoroModelStore.assetPackID)
    }
}

@MainActor
final class NaturalVoiceAssets: ObservableObject {
    enum State: Equatable {
        case checking
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .checking

    private let installer: any KokoroAssetInstalling

    init(installer: any KokoroAssetInstalling = BackgroundKokoroAssetInstaller()) {
        self.installer = installer
    }

    func refresh() async {
        state = await installer.isInstalled ? .installed : .notInstalled
    }

    func download() async {
        state = .downloading(0)
        do {
            try await installer.install { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(min(max(fraction, 0), 1))
                }
            }
            state = .installed
        } catch {
            state = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "Hearful could not download the natural voices. Please try again.")
        }
    }

    func remove() async {
        do {
            try await installer.remove()
            SpeechVoice.selectNatural(nil)
            KokoroEngines.reset()
            state = .notInstalled
        } catch {
            state = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "Hearful could not remove the natural voices. Please try again.")
        }
    }
}
