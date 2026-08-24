import Foundation
import Testing

@testable import Hearful

@Suite("Natural voice assets", .serialized)
@MainActor
struct NaturalVoiceAssetsTests {
    @Test func reportsAnAbsentOptionalDownload() async {
        let installer = FakeKokoroAssetInstaller(installed: false)
        let assets = NaturalVoiceAssets(installer: installer)

        await assets.refresh()

        #expect(assets.state == .notInstalled)
    }

    @Test func installsAndPublishesCompletion() async {
        let installer = FakeKokoroAssetInstaller(installed: false)
        let assets = NaturalVoiceAssets(installer: installer)

        await assets.download()

        #expect(assets.state == .installed)
        #expect(await installer.installCount == 1)
    }

    @Test func explainsAConnectionFailureWithoutExposingFrameworkDetails() async {
        let installer = FakeKokoroAssetInstaller(
            installed: false, installError: URLError(.notConnectedToInternet))
        let assets = NaturalVoiceAssets(installer: installer)

        await assets.download()

        #expect(
            assets.state == .failed(
                "Hearful couldn't download the natural voices. Check your internet connection and try again."))
    }

    @Test func explainsAStorageFailureWithoutExposingFrameworkDetails() async {
        let installer = FakeKokoroAssetInstaller(
            installed: false,
            installError: NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.Code.fileWriteOutOfSpace.rawValue))
        let assets = NaturalVoiceAssets(installer: installer)

        await assets.download()

        #expect(
            assets.state == .failed(
                "There isn't enough free storage for the natural voices. Free some storage and try again."))
    }

    @Test func hidesUnexpectedDownloadErrorDetails() async {
        let installer = FakeKokoroAssetInstaller(
            installed: false, installError: FakeAssetError.internalDetails)
        let assets = NaturalVoiceAssets(installer: installer)

        await assets.download()

        #expect(
            assets.state == .failed(
                "Hearful couldn't download the natural voices. Please try again."))
    }

    @Test func anInstalledButUnreadableDownloadIsNotOffered() async {
        let installer = FakeKokoroAssetInstaller(installed: true, usable: false)
        let assets = NaturalVoiceAssets(installer: installer)

        await assets.refresh()

        #expect(
            assets.state == .failed(
                "Hearful could not open the natural voice download. Please download it again."))
    }

    @Test func retryReplacesAnUnreadableLocalCopy() async {
        let installer = FakeKokoroAssetInstaller(installed: true, usable: false)
        let assets = NaturalVoiceAssets(installer: installer)

        await assets.download()

        #expect(assets.state == .installed)
        #expect(await installer.removeCount == 1)
        #expect(await installer.installCount == 1)
    }

    @Test func aFreshDownloadThatCannotBeOpenedIsRemoved() async {
        let installer = FakeKokoroAssetInstaller(
            installed: false, usableAfterInstall: false)
        let assets = NaturalVoiceAssets(installer: installer)

        await assets.download()

        #expect(
            assets.state == .failed(
                "Hearful could not open the natural voice download. Please download it again."))
        #expect(await installer.removeCount == 1)
    }

    @Test func removalReturnsToTheSystemVoice() async {
        let previous = SpeechVoice.naturalVoice
        defer { SpeechVoice.selectNatural(previous) }
        SpeechVoice.selectNatural(KokoroVoice.catalogue[0])

        let installer = FakeKokoroAssetInstaller(installed: true)
        let assets = NaturalVoiceAssets(installer: installer)
        await assets.refresh()
        await assets.remove()

        #expect(assets.state == .notInstalled)
        #expect(SpeechVoice.naturalVoice == nil)
        #expect(await installer.removeCount == 1)
    }

    @Test func publishesPausedProgressAndDoesNotStartADuplicateTransfer() async {
        let installer = FakeKokoroAssetInstaller(
            installed: false,
            statuses: [.began, .downloading(0.42), .paused],
            waitsForCancellation: true)
        let assets = NaturalVoiceAssets(installer: installer)

        let download = Task { await assets.download() }
        await waitUntil { assets.state == .paused(0.42) }

        await assets.refresh()
        await assets.download()

        #expect(assets.state == .paused(0.42))
        #expect(await installer.installCount == 1)

        await assets.cancelDownload()
        await download.value
    }

    @Test func cancellationStopsTheTransferAndReturnsToTheSystemVoiceOption() async {
        let installer = FakeKokoroAssetInstaller(
            installed: false,
            statuses: [.downloading(0.25)],
            waitsForCancellation: true)
        let assets = NaturalVoiceAssets(installer: installer)

        let download = Task { await assets.download() }
        await waitUntil { assets.state == .downloading(0.25) }
        await assets.cancelDownload()
        await download.value

        #expect(assets.state == .notInstalled)
        #expect(await installer.cancelCount == 1)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }
}

private enum FakeAssetError: LocalizedError {
    case internalDetails

    var errorDescription: String? { "BackgroundAssets HTTP response code 503." }
}

private actor FakeKokoroAssetInstaller: KokoroAssetInstalling {
    private(set) var installed: Bool
    private var usable: Bool
    private(set) var installCount = 0
    private(set) var cancelCount = 0
    private(set) var removeCount = 0
    private let installError: (any Error)?
    private let usableAfterInstall: Bool
    private let statuses: [KokoroAssetInstallStatus]
    private let waitsForCancellation: Bool
    private var cancellationRequested = false
    private var installContinuation: CheckedContinuation<Void, Never>?

    init(
        installed: Bool,
        usable: Bool? = nil,
        installError: (any Error)? = nil,
        usableAfterInstall: Bool = true,
        statuses: [KokoroAssetInstallStatus] = [.downloading(0.4), .downloading(1)],
        waitsForCancellation: Bool = false
    ) {
        self.installed = installed
        self.usable = usable ?? installed
        self.installError = installError
        self.usableAfterInstall = usableAfterInstall
        self.statuses = statuses
        self.waitsForCancellation = waitsForCancellation
    }

    var isInstalled: Bool { installed }

    func installedAssetsAreUsable() async -> Bool { installed && usable }

    func install(status: @escaping @Sendable (KokoroAssetInstallStatus) -> Void) async throws {
        installCount += 1
        if let installError { throw installError }
        for update in statuses {
            status(update)
        }
        if waitsForCancellation {
            await withCheckedContinuation { continuation in
                if cancellationRequested {
                    continuation.resume()
                } else {
                    installContinuation = continuation
                }
            }
            throw CancellationError()
        }
        installed = true
        usable = usableAfterInstall
    }

    func cancelInstall() {
        cancelCount += 1
        cancellationRequested = true
        let continuation = installContinuation
        installContinuation = nil
        continuation?.resume()
    }

    func remove() async throws {
        removeCount += 1
        installed = false
        usable = false
    }
}
