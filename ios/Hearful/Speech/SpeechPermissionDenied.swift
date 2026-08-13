/// Recognition could not start because permission to listen is missing.
///
/// Its own type, shared by both recognisers, because it is the one speech
/// failure that will never come right by trying again — and "sorry, I could
/// not hear you, tap and try again" is then advice that leads nowhere. She
/// cannot see a greyed-out button or a permission banner, so the difference
/// between "say that again" and "this needs fixing in Settings" has to survive
/// all the way up to something spoken.
struct SpeechPermissionDenied: Error {}
