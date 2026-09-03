# Store review and TestFlight notes

The machine-uploaded public listing and review notes now live under
[`app-store/`](../app-store/README.md). This document keeps the TestFlight copy,
the accessibility evidence, and the manual checks used while preparing a
submission.

Privacy policy URL: <https://audio-reader-production.up.railway.app/privacy>

---

## Beta App Description

The canonical copy is
[`app-store/metadata/en-GB/beta_description.txt`](../app-store/metadata/en-GB/beta_description.txt).
Every distributed build syncs it to TestFlight → Test Information, so edit it
there rather than in App Store Connect.

---

## What to Test

*TestFlight → per-build "What to Test" notes.*

Everything is reachable by voice. That is the main thing to try.

- Tap the microphone and say "subscribe to" the name of any podcast, blog or newsletter, then ask to play something from it.
- Ask in different ways: by topic ("the one about the Delian League"), by position ("the latest"), by show, or by guest.
- Try the transport words while something is playing: pause, skip, go back, faster, slower.
- Set a sleep timer e.g "stop in twenty minutes" and cancel it.
- Find your newsletter address in Settings, give it to an email-only newsletter (or send it an email yourself), then answer the sender that appears at the top of Latest and listen to what it sent.
- Subscribe to a blog or newsletter and play an article. It should read in the voice chosen under Settings, and pause, resume and scrub from the lock screen and headphones like any podcast.
- Change the reading voice in Settings and play the article again.
- Open an article on screen and tap the Safari button to check the original page opens.
- Try Siri without opening the app: "Play the latest In Our Time on Magpie", or "Ask Magpie" to open the microphone.
- Let an episode play to the end; you should hear a short tone rather than just silence.
- Take a phone call while listening. Playback should pause and resume by itself when the call ends.
- Pull your headphones out mid-episode. It should go quiet rather than continue out loud.

If you use VoiceOver, please tell us anywhere the app is awkward, silent when it should speak, or talks over itself. That feedback is more useful to us than anything else.

---

## App Review Notes

The canonical copy is [`app-store/review_notes.txt`](../app-store/review_notes.txt).
Keep reviewer instructions there so the local package and App Store Connect do
not drift apart. With the four `ASC_REVIEW_CONTACT_*` repository secrets set,
CI writes the notes and contact to both App Review (on a release tag) and Beta
App Review (on every distributed build); without them the notes stay a manual
paste.

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
