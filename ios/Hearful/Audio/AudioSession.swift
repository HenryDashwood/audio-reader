import AVFoundation

/// Playback and recording want different session categories, and switching
/// between them is the difference between audio that works and audio that
/// silently does nothing.
enum AudioSession {
    static func configureForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        // Coming back from listening, fully release the record configuration
        // first: switching category alone can leave the hardware at the
        // microphone's low sample rate (or Bluetooth's telephone-quality HFP
        // mode), which makes synthesised speech sound noticeably worse.
        if session.category == .playAndRecord {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        // .playback keeps audio going when the screen locks — paired with the
        // Background Modes → Audio capability, this is what lets her keep
        // listening with the phone in a pocket.
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
    }

    static func configureForListening() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord, mode: .measurement,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
