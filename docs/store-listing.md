# Store and TestFlight copy

Text to paste into App Store Connect. Kept here so it is version-controlled and
so the same wording is reused between Beta App Review and full App Store review
rather than being rewritten from memory each time.

Privacy policy URL: <https://audio-reader-production.up.railway.app/privacy>

---

## Beta App Description

*TestFlight → Test Information → Beta App Description. This is what testers
read on the TestFlight invitation.*

> Hearful is a podcast and article player you control by speaking.
>
> Tap the microphone and ask for what you want — "play the latest In Our Time",
> "subscribe to Astral Codex Ten", "play the one about Agincourt". It also reads
> written articles and newsletters aloud, so blogs and Substacks work the same
> way podcasts do.
>
> It remembers where you stopped in every episode, works from the lock screen
> and AirPods, and has a sleep timer you can set by voice.
>
> It is built to be used without looking at the screen, so if you use VoiceOver,
> that is the way it is meant to be used.

---

## What to Test

*TestFlight → per-build "What to Test" notes.*

Everything is reachable by voice. That is the main thing to try.

- Tap the microphone and say "subscribe to" the name of any podcast, blog or newsletter, then ask to play something from it.
- Ask in different ways: by topic ("the one about the Delian League"), by position ("the latest"), by show, or by guest.
- Try the transport words while something is playing: pause, skip, go back, faster, slower.
- Set a sleep timer e.g "stop in twenty minutes" and cancel it.
- Let an episode play to the end; you should hear a short tone rather than just silence.
- Take a phone call while listening. Playback should pause and resume by itself when the call ends.
- Pull your headphones out mid-episode. It should go quiet rather than continue out loud.

If you use VoiceOver, please tell us anywhere the app is awkward, silent when it should speak, or talks over itself. That feedback is more useful to us than anything else.

---

## App Review Notes

*App Store Connect → App Review Information → Notes. Written for a sighted
reviewer who has never seen an app driven this way.*

> Hearful is a podcast and article player designed for blind and partially
> sighted listeners. Almost everything is done by speaking rather than tapping,
> so it will not review like an ordinary media app — the library starts empty
> and fills up by voice.
>
> **No demo account is provided because none exists.** Sign in with Apple is the
> only sign-in method, so please sign in with your own Apple ID — an account is
> created automatically. There is no username or password to supply.
>
> Suggested path, which takes about two minutes:
>
> 1. Sign in with Apple on the first screen.
> 2. Tap the microphone button (top right of the Shows tab). Allow the
>    microphone and speech recognition prompts when they appear.
> 3. Say: "subscribe to In Our Time". The app searches, subscribes, and confirms
>    aloud. The show now appears in the Shows tab.
> 4. Tap the microphone again and say: "play the latest In Our Time". It
>    confirms what it found and starts playing.
> 5. Tap the microphone and say "pause", then "carry on".
>
> Shows can also be found by typing in the search field on the Shows tab, and
> episodes played by tapping them, if that is easier to verify.
>
> **On requiring an account:** an account is needed because the app's entire
> content is the user's own library — the shows they follow and their position
> in each episode — which is stored server-side so it follows them between
> devices. There is no shared or anonymous catalogue to browse without one. Sign
> in with Apple is the only method offered, and account deletion is available in
> Settings, which also revokes the Sign in with Apple connection.
>
> **On the microphone:** speech is converted to text on the device. Only the
> text is sent to our server, never an audio recording. This is described in
> full in the privacy policy.

---

## Accessibility declaration

*App Store Connect → App Accessibility.*

Worth completing properly rather than skipping — it is how someone searching for
an accessible player finds this app. Features supported today:

- **VoiceOver** — every control is labelled, and spoken responses are the
  primary output rather than an add-on.
- **Larger Text** — the interface uses semantic text styles throughout, so it
  scales with the system setting.

Only tick what has actually been verified by testing with the feature switched
on.
