# Google Play listing

This directory is the source of truth for Magpie's Google Play listing and
App content answers. It mirrors [`app-store/`](../app-store/README.md) for iOS.

The release workflow uploads the app bundle, mapping file, and release notes.
Listing copy and App content answers are maintained here and entered in Play
Console. Make lasting copy changes here first so the repository and Console do
not drift apart.

Build, signing, track selection, publishing, and recovery instructions are in
the canonical [mobile release guide](../docs/mobile-releases.md#android).

## Files

| File | Play Console location | Limit |
| --- | --- | --- |
| `listings/en-GB/title.txt` | Grow users → Store presence → Main store listing → App name | 30 characters |
| `listings/en-GB/short_description.txt` | Main store listing → Short description | 80 characters |
| `listings/en-GB/full_description.txt` | Main store listing → Full description | 4,000 characters |
| `release_notes/en-GB.txt` | Sent by `make android-upload` with each bundle (or pasted into Create release → Release notes, inside `<en-GB>` … `</en-GB>`). Update it before each upload. | 500 characters per language |
| `data_safety.md` | Policy and programmes → App content → Data safety | Questionnaire draft |
| `app_content.md` | Policy and programmes → App content: privacy policy, app access and reviewer instructions, ads, advertising ID, content rating, target audience, news apps, government/financial/health, foreground service, data deletion; also permission justifications | Questionnaire drafts |

Limits count characters (Unicode code points), not bytes. The descriptions use
`•`, `→` and curly quotes, which count as one character each. The files end with
a single trailing newline, which is not part of the field: paste the text without it.

Check lengths after any edit:

```bash
python3 - <<'EOF'
import pathlib
for path, limit in [("play-store/listings/en-GB/title.txt", 30),
                    ("play-store/listings/en-GB/short_description.txt", 80),
                    ("play-store/listings/en-GB/full_description.txt", 4000),
                    ("play-store/release_notes/en-GB.txt", 500)]:
    text = pathlib.Path(path).read_text(encoding="utf-8").rstrip("\n")
    print(f"{path}: {len(text)}/{limit}", "OK" if len(text) <= limit else "TOO LONG")
EOF
```

## Copy rules

- The product name is **Magpie**. The package is `com.henrydashwood.magpie`.
  The app name matches the iOS name, `Magpie: Reading and Listening`.
- Describe only features the Android build ships:
  - TalkBack and large-text support.
  - Android on-device speech recognition.
  - System voices and an optional downloadable natural voice for narration.
  - Downloaded podcasts and prepared articles for offline listening.
  - Home-screen shortcuts and Quick Settings tiles.
  - Sharing from the browser to Saved.
  - Google or Apple sign-in.

  Do not mention Siri, Shortcuts, VoiceOver, Safari or iPhone features.
  Do not claim Gemini or Google Assistant integration: AppFunctions is an
  experimental Google preview that has not been accepted on a phone
  (see the [acceptance matrix](../docs/android-acceptance.md)). Offline claims
  must require downloaded audio/text and installed voice assets; discovery,
  web capture and remote assistant requests still require a connection.
- Play policy forbids keyword stuffing, ranking or performance claims ("best",
  "#1", "top"), promotional prices, calls to action such as "download now",
  unverified testimonials, and emoji or ALL-CAPS used for attention.
- Keep privacy claims identical to the
  [privacy policy](https://audio-reader-production.up.railway.app/privacy) and
  the Data safety answers. If one changes, update all three.

## Graphics and Console settings

- Committed graphics: [app icon](graphics/icon-512.png),
  [feature graphic](graphics/feature-graphic-1024x500.png), and six
  [phone screenshots](screenshots/phone/).
- Screenshots use the App Store set's fictional library
  (`scripts/seed_app_store_screenshots.py`), served by the instrumented
  `PlayStoreScreenshots` test without a backend or personal data. Start an AVD
  with enough space using `make android-emulator`, then run
  `make android-play-screenshots`. The test uses a 9:41 demo status bar,
  UK dates and a 1080 × 1920 screen, and restores the emulator afterwards.
- Console-owned settings include category (Music & Audio), contact email,
  [support website](https://audio-reader-production.up.railway.app/support),
  countries, app pricing and tags. See [App content](app_content.md).
- Reviewer contact details are not committed, as with the iOS listing.

Recheck Play's current field limits and policy wording in the Console before
submission. They change independently of this repository.
