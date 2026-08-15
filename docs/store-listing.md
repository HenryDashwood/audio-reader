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
an accessible player finds this app.

Apple asks you to declare only features supported across the app's *primary*
functionality, so each of these needs verifying with the feature actually
switched on. A code audit is not enough: one read of the source turned up a
mini player whose tap target was invisible to VoiceOver, leaving the entire
player screen — scrubber, speed, sleep timer — unreachable without sight. That
bug is fixed, but it is the reason this section waits for a device pass.

| Feature | Status | Evidence |
| --- | --- | --- |
| VoiceOver | **Verify before declaring** | Every control now carries a label or is deliberately hidden. Never tested by ear. |
| Larger Text | **Likely, verify** | All text uses semantic styles, so it scales. The only fixed sizes are SF Symbols — decorative icons, or the already-large transport glyphs. Check nothing truncates at the largest accessibility sizes. |
| Differentiate Without Colour Alone | **Satisfied** | Every colour-coded state also carries text or a symbol: "Not updating" has a warning icon and words, the playing episode is bold with a speaker icon, progress is written out as "12 min left". |
| Sufficient Contrast | **Unverified** | Uses system semantic colours throughout, which are designed to pass, but nothing has been measured. |
| Captions, Audio Descriptions | **Do not declare** | No video content. Transcripts of episode audio are not offered. |

Things worth listening for during the pass, in order of how badly they would
undermine a declaration:

1. **The voice sheet starts listening as it appears.** VoiceOver will be
   announcing the sheet at the same moment. If they collide, either she talks
   over VoiceOver or the microphone transcribes VoiceOver's own speech.
2. The "Open Settings" button in the permission state — that view switches its
   accessibility grouping so the button is reachable; confirm both it and the
   tap-anywhere behaviour still work.
3. Episode rows combine title, date, length and progress into one label. Check
   it reads as a sentence rather than a run-on.
4. The offline notice is a list row rather than a banner, specifically so it
   lands in swipe order. Confirm it does.
