# Google Play listing

This directory is the source of truth for Magpie's Google Play listing and
App content answers. It mirrors [`app-store/`](../app-store/README.md) for iOS.

No upload workflow exists yet. The Play Console account is awaiting identity
verification. **Every field here is entered by hand in Play Console.** Make lasting
copy changes here first, then paste them in, so the repository and the Console do
not drift apart. Nothing in this directory is uploaded, published or submitted
automatically.

Release preparation and remaining gates are in
[`docs/android-release.md`](../docs/android-release.md).

## Files

| File | Play Console location | Limit |
| --- | --- | --- |
| `listings/en-GB/title.txt` | Grow users → Store presence → Main store listing → App name | 30 characters |
| `listings/en-GB/short_description.txt` | Main store listing → Short description | 80 characters |
| `listings/en-GB/full_description.txt` | Main store listing → Full description | 4,000 characters |
| `release_notes/en-GB.txt` | Test and release → (track) → Create release → Release notes, inside `<en-GB>` … `</en-GB>` | 500 characters per language |
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
  - Installed offline Google voices for narration.
  - Home-screen shortcuts and Quick Settings tiles.
  - Sharing from the browser to Saved.
  - Google or Apple sign-in.

  Do not mention Siri, Shortcuts, VoiceOver, Safari or iPhone features.
  Do not claim Gemini or Google Assistant integration: AppFunctions is an
  experimental Google preview that has not been accepted on a phone
  (`android/README.md`). Do not claim podcast downloads or offline listening,
  which are not implemented.
- Play policy forbids keyword stuffing, ranking or performance claims ("best",
  "#1", "top"), promotional prices, calls to action such as "download now",
  unverified testimonials, and emoji or ALL-CAPS used for attention.
- Keep privacy claims identical to the
  [privacy policy](https://audio-reader-production.up.railway.app/privacy) and
  the Data safety answers. If one changes, update all three.

## Not yet kept here

These are prepared in Play Console directly or remain to be created:

- **Graphics:**
  - App icon: 512 × 512 PNG, 32-bit, up to 1 MB. Derive it from
    `app-store/assets/magpie-mark-transparent.png` on the app's `#101317`
    background.
  - Feature graphic: 1024 × 500 JPEG or 24-bit PNG with no alpha.
  - Phone screenshots: 2–8, each side between 320 and 3,840 px, aspect ratio
    no more than 2:1.
  - Optionally 7- and 10-inch tablet screenshots.

  Screenshots must show real app behaviour and no personal data. Take them from
  a Play-signed internal build. `make android-screenshot` saves captures under
  `build/android-artifacts/`.
- **Store settings:**
  - App category: Music & Audio (confirmed by the owner; see `app_content.md`).
  - Contact email and website (`https://audio-reader-production.up.railway.app/support`).
  - Countries, pricing (free), and tags.
- Reviewer contact details are not committed, just as in `app-store/`.

Recheck Play's current field limits and policy wording in the Console before
submission. They change independently of this repository.
