import BackgroundAssets
import Combine
import Foundation

nonisolated protocol KokoroAssetInstalling: Sendable {
    var isInstalled: Bool { get async }
    func installedAssetsAreUsable() async -> Bool
    func install(status: @escaping @Sendable (KokoroAssetInstallStatus) -> Void) async throws
    func cancelInstall() async
    func remove() async throws
}

nonisolated enum KokoroAssetInstallStatus: Sendable {
    case began
    case downloading(Double)
    case paused
}

nonisolated enum KokoroAssetInstallError: LocalizedError {
    case assetPackMissing
    case incompleteDownload
    case unusableDownload

    var errorDescription: String? {
        switch self {
        case .assetPackMissing:
            "The natural voices are not available for this version of Hearful yet."
        case .incompleteDownload:
            "The natural voice download did not contain all of the files Hearful needs."
        case .unusableDownload:
            "Hearful could not open the natural voice download. Please download it again."
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
    private var activeProgress: Progress?
    private var cancellationRequested = false

    var isInstalled: Bool { KokoroModelStore.isInstalled }

    func installedAssetsAreUsable() async -> Bool {
        guard KokoroModelStore.isInstalled, let engine = KokoroEngines.shared else { return false }
        return !(await engine.availableVoices()).isEmpty
    }

    func install(status: @escaping @Sendable (KokoroAssetInstallStatus) -> Void) async throws {
        cancellationRequested = false
        activeProgress = nil
        let updates = manager.statusUpdates(forAssetPackWithID: KokoroModelStore.assetPackID)
        let progressTask = Task {
            for await update in updates {
                guard !Task.isCancelled else { return }
                switch update {
                case .began:
                    status(.began)
                case .paused:
                    status(.paused)
                case .downloading(_, let downloadProgress):
                    activeProgress = downloadProgress
                    if cancellationRequested {
                        downloadProgress.cancel()
                    }
                    status(.downloading(downloadProgress.fractionCompleted))
                case .finished:
                    status(.downloading(1))
                    return
                case .failed:
                    return
                @unknown default:
                    break
                }
            }
        }
        defer {
            progressTask.cancel()
            activeProgress = nil
            cancellationRequested = false
        }

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
        status(.downloading(1))
    }

    func cancelInstall() {
        cancellationRequested = true
        activeProgress?.cancel()
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
        case waiting
        case downloading(Double)
        case paused(Double)
        case cancelling(Double)
        case installed
        case failed(String)
    }

    static let shared = NaturalVoiceAssets()

    @Published private(set) var state: State = .checking

    private let installer: any KokoroAssetInstalling
    private var downloadIsActive = false
    private var cancellationRequested = false
    private var latestProgress = 0.0

    init(installer: any KokoroAssetInstalling = BackgroundKokoroAssetInstaller()) {
        self.installer = installer
    }

    func refresh() async {
        // A newly-created Settings view must observe the process-wide transfer
        // rather than replacing its progress with a fresh disk check.
        guard !downloadIsActive else { return }
        guard await installer.isInstalled else {
            state = .notInstalled
            return
        }
        state = await installer.installedAssetsAreUsable()
            ? .installed
            : .failed(KokoroAssetInstallError.unusableDownload.localizedDescription)
    }

    func download() async {
        // Settings can briefly create more than one task during navigation.
        // Only the process-wide coordinator is allowed to own the transfer.
        guard !downloadIsActive else { return }
        downloadIsActive = true
        cancellationRequested = false
        latestProgress = 0
        state = .waiting
        defer {
            downloadIsActive = false
            cancellationRequested = false
        }

        do {
            // A failed validation means Retry must fetch a fresh copy, not let
            // Background Assets immediately return the same local files.
            if await installer.isInstalled, !(await installer.installedAssetsAreUsable()) {
                try await installer.remove()
                KokoroEngines.reset()
            }

            guard !cancellationRequested else {
                state = .notInstalled
                return
            }

            try await installer.install { [weak self] status in
                Task { @MainActor in
                    self?.apply(status)
                }
            }

            if cancellationRequested {
                await settleAfterCancellation()
                return
            }

            let usable = await installer.installedAssetsAreUsable()
            if cancellationRequested {
                state = usable ? .installed : .notInstalled
                return
            }
            guard usable else {
                try? await installer.remove()
                KokoroEngines.reset()
                throw KokoroAssetInstallError.unusableDownload
            }
            state = .installed
        } catch {
            if cancellationRequested {
                await settleAfterCancellation()
            } else {
                state = .failed(NaturalVoiceAssetErrorMessage.download(error))
            }
        }
    }

    func cancelDownload() async {
        guard downloadIsActive else { return }
        cancellationRequested = true
        state = .cancelling(latestProgress)
        await installer.cancelInstall()
    }

    func remove() async {
        guard !downloadIsActive else { return }
        do {
            try await installer.remove()
            SpeechVoice.selectNatural(nil)
            KokoroEngines.reset()
            state = .notInstalled
        } catch {
            state = .failed(NaturalVoiceAssetErrorMessage.removal(error))
        }
    }

    private func apply(_ status: KokoroAssetInstallStatus) {
        guard downloadIsActive, !cancellationRequested else { return }
        switch status {
        case .began:
            state = .waiting
        case .downloading(let fraction):
            latestProgress = min(max(fraction, 0), 1)
            state = .downloading(latestProgress)
        case .paused:
            state = .paused(latestProgress)
        }
    }

    private func settleAfterCancellation() async {
        if await installer.isInstalled, await installer.installedAssetsAreUsable() {
            state = .installed
        } else {
            state = .notInstalled
        }
    }
}

private enum NaturalVoiceAssetErrorMessage {
    private static let connectionFailure =
        "Hearful couldn't download the natural voices. Check your internet connection and try again."
    private static let storageFailure =
        "There isn't enough free storage for the natural voices. Free some storage and try again."
    private static let genericDownloadFailure =
        "Hearful couldn't download the natural voices. Please try again."

    static func download(_ error: any Error) -> String {
        if let installError = error as? KokoroAssetInstallError {
            return installError.localizedDescription
        }

        let errors = errorChain(error)
        if errors.contains(where: isStorageFailure) {
            return storageFailure
        }
        if errors.contains(where: isConnectionFailure) {
            return connectionFailure
        }
        return genericDownloadFailure
    }

    static func removal(_ error: any Error) -> String {
        "Hearful couldn't remove the natural voices. Restart Hearful and try again."
    }

    private static func errorChain(_ error: any Error) -> [NSError] {
        var result: [NSError] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let item = current, depth < 8 {
            result.append(item)
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return result
    }

    private static func isConnectionFailure(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        let codes: Set<Int> = [
            URLError.Code.timedOut.rawValue,
            URLError.Code.cannotFindHost.rawValue,
            URLError.Code.cannotConnectToHost.rawValue,
            URLError.Code.networkConnectionLost.rawValue,
            URLError.Code.dnsLookupFailed.rawValue,
            URLError.Code.notConnectedToInternet.rawValue,
            URLError.Code.internationalRoamingOff.rawValue,
            URLError.Code.callIsActive.rawValue,
            URLError.Code.dataNotAllowed.rawValue,
        ]
        return codes.contains(error.code)
    }

    private static func isStorageFailure(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.Code.fileWriteOutOfSpace.rawValue)
            || (error.domain == NSPOSIXErrorDomain
                && error.code == Int(POSIXErrorCode.ENOSPC.rawValue))
    }
}
