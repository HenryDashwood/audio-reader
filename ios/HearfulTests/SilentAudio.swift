import AVFoundation
import Testing

func silentAudio(seconds: Int = 1) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(8_000 * seconds)))
    buffer.frameLength = buffer.frameCapacity
    let samples = try #require(buffer.floatChannelData)
    samples[0].update(repeating: 0, count: Int(buffer.frameLength))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}
