/// A recogniser failure that says whether it is worth trying that recogniser
/// again next time.
///
/// The fallback deliberately writes a recogniser off after one failure,
/// because one that cannot initialise fails the same way every time and
/// retrying costs a second or two before she can speak. That reasoning holds
/// for "this device has no compatible audio format" and not at all for "the
/// microphone had not woken up yet" — the first is permanent, the second was
/// gone by the next tap. Conflating them means one cold start downgrades her
/// to the weaker recogniser for the rest of the session.
protocol TransientRecognitionFailure: Error {
    var isTransient: Bool { get }
}

/// The recogniser had already told her to speak before it failed. Starting a
/// backup at that point would silently ask her to repeat words that have
/// already gone, so the fallback must surface the failure instead.
protocol RecognitionFailureAfterCapture: Error {}
