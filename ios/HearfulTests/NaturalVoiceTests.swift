import AVFoundation
import Foundation
import Testing

@testable import Hearful

@Suite("Natural voice")
struct NaturalVoiceTests {
    typealias Token = NaturalVoicePhonemizer.Token

    /// A sentence's tokens from native/g2p and its frames from Kokoro, with the word spans Kokoro's own
    /// `join_timestamps` gives them (text-to-speech notebook 100's `words`), generated in Python.
    @Test func wordsLandWhereKokoroPutsThem() {
        let tokens = [
            ("Speed", "spˈiːd", " ", 0, 5), ("comes", "kˈʌmz", " ", 6, 11), ("from", "fɹɒm", " ", 12, 16),
            ("the", "ðə", " ", 17, 20), ("voice", "vˈYs", " ", 21, 26), ("itself", "ɪtsˈɛlf", "", 27, 33),
            (",", ",", " ", 33, 34), ("not", "nˌɒt", " ", 35, 38), ("from", "fɹɒm", " ", 39, 43),
            ("stretching", "stɹˈɛʧɪŋ", " ", 44, 54), ("the", "ði", " ", 55, 58), ("audio", "ˈɔːdɪQ", " ", 59, 64),
            ("afterwards", "ˈɑːftəwədz", "", 65, 75), (".", ".", "", 75, 76),
        ].map { Token(text: $0.0, phonemes: $0.1, whitespace: $0.2, start: $0.3, end: $0.4) }
        let frames = [
            14, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 2, 2, 3, 3, 2, 2, 2, 3, 3, 3, 3, 4, 12, 3,
            2, 1, 2, 2, 1, 2, 1, 1, 2, 2, 2, 2, 2, 1, 2, 3, 3, 2, 1, 1, 1, 2, 2, 2, 1, 2, 3, 3, 2, 2, 2, 1, 2, 2, 2, 2,
            2, 3, 3, 23, 7, 1,
        ]
        let expected = [
            (0, 5, 6600, 15000), (6, 11, 15000, 22200), (12, 16, 22200, 25500), (17, 20, 25500, 27600),
            (21, 26, 27600, 34800), (27, 33, 34800, 53400), (35, 38, 55800, 60600), (39, 43, 60600, 65400),
            (44, 54, 65400, 75900), (55, 58, 75900, 78600), (59, 64, 78600, 87600), (65, 75, 87600, 113400),
        ].map { NaturalVoiceEngine.Word(characters: $0.0 ..< $0.1, samples: $0.2 ..< $0.3) }
        #expect(NaturalVoiceEngine.words(tokens, frames: frames) == expected)
    }

    /// "Up - down." phonemizes as "ʌp␣␣dWn.": the dash says nothing but keeps its space, one phoneme.
    @Test func aSilentTokenTakesOnlyItsSpaceSoLaterWordsKeepTheirPlace() {
        let tokens = [("Up", "ʌp", " ", 0, 2), ("-", "", " ", 3, 4), ("down", "dWn", "", 5, 9), (".", ".", "", 9, 10)]
            .map { Token(text: $0.0, phonemes: $0.1, whitespace: $0.2, start: $0.3, end: $0.4) }
        let frames = [Int](repeating: 2, count: 10)  // Start, eight phonemes, end
        #expect(NaturalVoiceEngine.words(tokens, frames: frames) == [
            NaturalVoiceEngine.Word(characters: 0 ..< 2, samples: 0 ..< 3_000),
            NaturalVoiceEngine.Word(characters: 5 ..< 9, samples: 4_200 ..< 8_400),
        ])
    }

    @Test func trimmingKeepsALittleEitherSideAndMovesTheWords() {
        let samples = [Float](repeating: 0.5, count: 48_000)
        let words = [NaturalVoiceEngine.Word(characters: 0 ..< 3, samples: 12_000 ..< 24_000)]
        let trimmed = NaturalVoiceEngine.trimmed(samples, words: words)
        #expect(trimmed.samples.count == 2_400 + 12_000 + 6_000)
        #expect(trimmed.words == [NaturalVoiceEngine.Word(characters: 0 ..< 3, samples: 2_400 ..< 14_400)])
    }

    @Test func trimmingFollowsWhatIsHeardRatherThanTheWordTimings() {
        // Speech from 0.5 s to 0.8 s, though the word's timing runs on to 1 s, as Kokoro's last word does
        var samples = [Float](repeating: 0.001, count: 48_000)
        for i in 12_000 ..< 19_200 { samples[i] = 0.5 }
        let words = [NaturalVoiceEngine.Word(characters: 0 ..< 3, samples: 12_000 ..< 24_000)]
        let trimmed = NaturalVoiceEngine.trimmed(samples, words: words)
        #expect(trimmed.samples.count == 1_200 + 7_200 + 4_800)
        #expect(trimmed.words == [NaturalVoiceEngine.Word(characters: 0 ..< 3, samples: 1_200 ..< 13_200)])
    }

    @Test func paddingRepeatsTheSentence() {
        #expect(NaturalVoiceEngine.repeated([1, 2, 3], to: 7) == [1, 2, 3, 1, 2, 3, 1])
    }

    @Test func featuresAreRepeatedOncePerFrame() {
        // Two phonemes, three channels: as Tokens' d, (phonemes, channels)
        let d: [Float] = [1, 2, 3, 4, 5, 6]
        #expect(NaturalVoiceEngine.gather(d, rows: 2, columns: 3, at: [0, 0, 1], transposing: true)
            == [1, 1, 4, 2, 2, 5, 3, 3, 6])
        // As Tokens' t_en, (channels, phonemes)
        let t: [Float] = [1, 2, 3, 4]
        #expect(NaturalVoiceEngine.gather(t, rows: 2, columns: 2, at: [1, 0, 0], transposing: false) == [2, 1, 1, 4, 3, 3])
    }

    @Test func abbreviationsDoNotEndSentences() {
        let text = "Patreon paid on Thursday, from No. 10 Downing St. to St. Paul's. Then it rained. It was 3 p.m. on Jan. 4."
        let sentences = NaturalVoiceSynthesizer.sentences(in: text).map(\.text)
        #expect(sentences.count == 3)
        #expect(sentences.first?.hasSuffix("St. Paul's. ") == true)
        let offsets = NaturalVoiceSynthesizer.sentences(in: text).map(\.offset)
        #expect(offsets.first == 0)
        #expect(offsets.dropFirst().allSatisfy { (text as NSString).substring(from: $0).first?.isUppercase == true })
    }

    @Test func longSentencesSplitAtTheClauseNearestTheMiddle() throws {
        let text = "This is the first half of it, and this is the second half of the sentence"
        #expect(String(text[..<NaturalVoiceSynthesizer.splitPoint(text)!]) == "This is the first half of it, ")
        let plain = "one two three four five six"
        #expect(String(plain[..<NaturalVoiceSynthesizer.splitPoint(plain)!]) == "one two three ")

        // A first half ends in the space it was cut after. Splitting it again
        // must not choose that space: the half came back whole, for ever.
        let sentence = "But it seems to me like our current equilibrium is that US midterm election prediction markets "
            + "are big enough ($2.5 billion of volume on Kalshi) to provide real incentives for accurate predictions, "
            + "but not big enough to, like, swamp the actual elections."
        var pending = [sentence]
        var pieces = 0
        while let piece = pending.popLast(), piece.count > 20 {
            let cut = try #require(NaturalVoiceSynthesizer.splitPoint(piece))
            let head = String(piece[..<cut]), tail = String(piece[cut...])
            #expect(head.count < piece.count && tail.count < piece.count, "\(piece) did not get shorter")
            #expect(head.contains(where: \.isLetter) && tail.contains(where: \.isLetter))
            pending += [head, tail]
            pieces += 1
            try #require(pieces < 100, "Splitting never finished")
        }
        #expect(NaturalVoiceSynthesizer.splitPoint("trailing, ") == nil)
    }

    @Test func speedIsTheInverseOfTheReadersRate() {
        for multiplier: Float in [0.8, 1, 1.25, 1.5, 2, 2.5] {
            let rate = ArticlePlayer.utteranceRate(for: multiplier)
            #expect(abs(NaturalVoiceSynthesizer.speed(forUtteranceRate: rate) - multiplier) < 0.001)
        }
    }

    @Test func voicesAreNamedForTheirAccent() {
        #expect(NaturalVoice(id: "bf_emma").label == "Emma (British)")
        #expect(NaturalVoice(id: "af_heart").isBritish == false)
    }
}

@Suite("Natural voice download")
@MainActor
struct NaturalVoiceDownloadTests {
    /// Stands in for Background Assets: "installs" by making a complete voice folder, or fails as told.
    actor FakeInstaller: NaturalVoiceInstalling {
        let folder: URL
        var failure: (any Error)?
        var complete = true
        private(set) var removals = 0
        private var installed = false

        init(failure: (any Error)? = nil, complete: Bool = true) {
            folder = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
            self.failure = failure
            self.complete = complete
        }

        var installedFolder: URL? { installed && NaturalVoiceStore.isUsable(folder) ? folder : nil }

        func install(status: @escaping @Sendable (NaturalVoiceInstallStatus) -> Void) async throws {
            status(.downloading(0.5))
            if let failure { throw failure }
            let files = NaturalVoiceStore.requiredFiles.dropLast(complete ? 0 : 1) + ["voices/bf_emma.bin"]
            for file in files {
                let url = folder.appending(path: file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            }
            installed = true
        }

        func cancelInstall() {}

        func remove() async throws {
            removals += 1
            installed = false
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func aCompleteDownloadOffersItsSpeakers() async {
        let download = NaturalVoiceDownload(installer: FakeInstaller())
        await download.refresh()
        #expect(download.state == .notInstalled)
        await download.download()
        #expect(download.state == .installed([NaturalVoice(id: "bf_emma")]))
    }

    @Test func anIncompleteDownloadIsRemovedSoTryAgainStartsAfresh() async {
        let installer = FakeInstaller(complete: false)
        let download = NaturalVoiceDownload(installer: installer)
        await download.download()
        #expect(download.state == .failed(NaturalVoiceInstallError.unusableDownload.localizedDescription))
        #expect(await installer.removals == 1)
    }

    @Test func beingOfflineSaysSo() async {
        let download = NaturalVoiceDownload(installer: FakeInstaller(failure: URLError(.notConnectedToInternet)))
        await download.download()
        guard case .failed(let message) = download.state else {
            Issue.record("expected a failure, got \(download.state)")
            return
        }
        #expect(message.contains("internet connection"))
    }

    @Test func removingGoesBackToTheAppleVoice() async {
        let defaults = UserDefaults.standard
        let download = NaturalVoiceDownload(installer: FakeInstaller())
        await download.download()
        NaturalVoiceStore.select(NaturalVoice(id: "bf_emma"))
        await download.remove()
        #expect(download.state == .notInstalled)
        #expect(defaults.string(forKey: NaturalVoiceStore.selectionKey) == nil)
    }
}
