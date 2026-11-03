import BackgroundAssets
import Combine
import Foundation
import System
import os

nonisolated private let log = Logger(subsystem: "com.henrydashwood.hearful", category: "natural-voice")

/// What the download needs from Background Assets, so the coordinator can be tested without Apple's servers.
nonisolated protocol NaturalVoiceInstalling: Sendable {
    /// The voice's folder, if it's here and complete.
    var installedFolder: URL? { get async }
    func install(status: @escaping @Sendable (NaturalVoiceInstallStatus) -> Void) async throws
    func cancelInstall() async
    func remove() async throws
}

nonisolated enum NaturalVoiceInstallStatus: Sendable {
    case began
    case downloading(Double)
    case paused
}

nonisolated enum NaturalVoiceInstallError: LocalizedError {
    case assetPackMissing
    case unusableDownload

    var errorDescription: String? {
        switch self {
        case .assetPackMissing: "The natural voice isn't available for this version of Magpie yet."
        case .unusableDownload: "Magpie couldn't open the natural voice download. Please download it again."
        }
    }
}

/// The voice's on-demand, Apple-hosted asset pack. The app asks for it only after she taps Download.
///
/// From the August Kokoro prototype, which had this working against Apple's mock server.
actor BackgroundNaturalVoiceInstaller: NaturalVoiceInstalling {
    private let manager = AssetPackManager.shared
    private var activeProgress: Progress?
    private var cancellationRequested = false

    var installedFolder: URL? { NaturalVoiceStore.folder }

    func install(status: @escaping @Sendable (NaturalVoiceInstallStatus) -> Void) async throws {
        cancellationRequested = false
        activeProgress = nil
        let updates = manager.statusUpdates(forAssetPackWithID: NaturalVoiceStore.assetPackID)
        let progressTask = Task {
            for await update in updates {
                guard !Task.isCancelled else { return }
                switch update {
                case .began:
                    status(.began)
                case .paused:
                    status(.paused)
                case .downloading(_, let progress):
                    self.track(progress)
                    status(.downloading(progress.fractionCompleted))
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
        guard NaturalVoiceStore.folder != nil else {
            let vocab = try? manager.url(for: FilePath("NaturalVoice/vocab.json"))
            let missing = vocab.map { url in
                NaturalVoiceStore.requiredFiles.filter {
                    !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: $0).path)
                }
            }
            log.error("Downloaded voice unusable: vocab.json at \(vocab?.path ?? "nowhere", privacy: .public), missing \(missing?.joined(separator: ", ") ?? "everything", privacy: .public)")
            throw NaturalVoiceInstallError.unusableDownload
        }
        status(.downloading(1))
    }

    func cancelInstall() {
        cancellationRequested = true
        activeProgress?.cancel()
    }

    func remove() async throws {
        try await manager.remove(assetPackWithID: NaturalVoiceStore.assetPackID)
    }

    private func track(_ progress: Progress) {
        activeProgress = progress
        if cancellationRequested { progress.cancel() }
    }

    private func assetPack() async throws -> AssetPack {
        #if compiler(>=6.4)
            if #available(iOS 27, *) {
                guard let pack = try await manager.manifest.assetPack(withID: NaturalVoiceStore.assetPackID) else {
                    throw NaturalVoiceInstallError.assetPackMissing
                }
                return pack
            }
        #endif
        return try await manager.assetPack(withID: NaturalVoiceStore.assetPackID)
    }
}

/// The one download of the natural voice, for Settings to show and drive. Process-wide, so leaving and
/// reopening Settings shows the same transfer rather than starting another.
@MainActor
final class NaturalVoiceDownload: ObservableObject {
    enum State: Equatable {
        case checking
        case notInstalled
        case waiting
        case downloading(Double)
        case paused(Double)
        case cancelling(Double)
        case installed([NaturalVoice])
        case failed(String)
    }

    /// About what the download costs, for the button that starts it: the asset pack is 158 MB with 13 speakers.
    static let approximateSize = "160 MB"

    static let shared = NaturalVoiceDownload()

    @Published private(set) var state: State = .checking

    private let installer: any NaturalVoiceInstalling
    private var isActive = false
    private var cancellationRequested = false
    private var latestProgress = 0.0

    init(installer: any NaturalVoiceInstalling = BackgroundNaturalVoiceInstaller()) {
        self.installer = installer
    }

    func refresh() async {
        guard !isActive else { return }  // Settings reopened mid-download: keep showing the transfer
        state = await installedState() ?? .notInstalled
    }

    func download() async {
        guard !isActive else { return }
        isActive = true
        cancellationRequested = false
        latestProgress = 0
        state = .waiting
        defer {
            isActive = false
            cancellationRequested = false
        }
        do {
            try await installer.install { [weak self] status in
                Task { @MainActor in self?.apply(status) }
            }
            if let installed = await installedState() {
                state = installed
                return
            }
            if cancellationRequested {
                state = .notInstalled
                return
            }
            try? await installer.remove()  // So Try Again fetches a fresh copy rather than these files
            throw NaturalVoiceInstallError.unusableDownload
        } catch {
            if cancellationRequested {
                state = await installedState() ?? .notInstalled
            } else {
                log.error("Natural voice download failed: \(String(describing: error), privacy: .public)")
                state = .failed(Self.message(for: error))
            }
        }
    }

    func cancel() async {
        guard isActive else { return }
        cancellationRequested = true
        state = .cancelling(latestProgress)
        await installer.cancelInstall()
    }

    func remove() async {
        guard !isActive else { return }
        NaturalVoiceStore.select(nil)
        NaturalVoiceSynthesizer.releaseEngines()
        do {
            try await installer.remove()
            state = .notInstalled
        } catch {
            state = .failed("Magpie couldn't remove the natural voice. Restart Magpie and try again.")
        }
    }

    private func installedState() async -> State? {
        guard let folder = await installer.installedFolder else { return nil }
        return .installed(NaturalVoiceStore.voices(in: folder))
    }

    private func apply(_ status: NaturalVoiceInstallStatus) {
        guard isActive, !cancellationRequested else { return }
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

    /// What to tell her: what went wrong, in terms of what she can do about it.
    nonisolated static func message(for error: any Error) -> String {
        if let install = error as? NaturalVoiceInstallError { return install.localizedDescription }
        var chain: [NSError] = []
        var current: NSError? = error as NSError
        while let item = current, chain.count < 8 {
            chain.append(item)
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if chain.contains(where: {
            ($0.domain == NSCocoaErrorDomain && $0.code == CocoaError.Code.fileWriteOutOfSpace.rawValue)
                || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(POSIXErrorCode.ENOSPC.rawValue))
        }) {
            return "There isn't enough free storage for the natural voice. Free some storage and try again."
        }
        let offline: Set<URLError.Code> = [
            .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
            .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
        ]
        if chain.contains(where: { $0.domain == NSURLErrorDomain && offline.contains(URLError.Code(rawValue: $0.code)) }) {
            return "Magpie couldn't download the natural voice. Check your internet connection and try again."
        }
        return "Magpie couldn't download the natural voice. Please try again."
    }
}
