import AVFoundation

/// Playback and recording want different session categories, and switching
/// between them is the difference between audio that works and audio that
/// silently does nothing.
enum AudioSession {
    static func configureForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
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
