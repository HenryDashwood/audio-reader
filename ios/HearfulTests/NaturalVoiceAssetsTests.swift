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

    @Test func exposesADownloadFailureForRetry() async {
        let installer = FakeKokoroAssetInstaller(
            installed: false, installError: FakeAssetError.offline)
        let assets = NaturalVoiceAssets(installer: installer)

        await assets.download()

        #expect(assets.state == .failed("The download is offline."))
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
}

private enum FakeAssetError: LocalizedError {
    case offline

    var errorDescription: String? { "The download is offline." }
}

private actor FakeKokoroAssetInstaller: KokoroAssetInstalling {
    private(set) var installed: Bool
    private(set) var installCount = 0
    private(set) var removeCount = 0
    private let installError: (any Error)?

    init(installed: Bool, installError: (any Error)? = nil) {
        self.installed = installed
        self.installError = installError
    }

    var isInstalled: Bool { installed }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        installCount += 1
        if let installError { throw installError }
        progress(0.4)
        installed = true
        progress(1)
    }

    func remove() async throws {
        removeCount += 1
        installed = false
    }
}
