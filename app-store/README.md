# App Store listing

This directory is the source of truth for Magpie's public App Store listing.
Do not make a lasting copy change only in App Store Connect: make it here, let
CI validate it, and sync it from a release tag.

## What is kept here

- `config.json` identifies the app and holds non-localised version settings.
- `metadata/<locale>/` contains one plain-text field per App Store field.
- `review_notes.txt` is the non-public explanation for App Review, and for
  Beta App Review on TestFlight. Contact details are deliberately not
  committed.
- `metadata/<locale>/beta_description.txt` is the Beta App Description
  testers read on the TestFlight invitation. Optional: a locale without one
  keeps whatever TestFlight already has.
- `screenshots/<locale>/<display type>/` contains the final ordered images.
  Filenames sort into their storefront order, so use names such as
  `01-latest.jpg`, `02-shows.jpg`, and `03-player.jpg`.

The current screenshot folders cover both device families the Xcode target
supports:

- `APP_IPHONE_67`: a 6.9-inch iPhone screenshot. Apple still uses the older
  `67` name for this API upload well. The preferred simulator is an iPhone 17
  Pro Max, whose portrait output is 1320 × 2868.
- `APP_IPAD_PRO_3GEN_129`: a 13-inch/12.9-inch iPad screenshot. The accepted
  portrait sizes include 2064 × 2752 and 2048 × 2732.

Apple accepts one to ten screenshots in a set. Images must all have an accepted
size and must not have transparency. Empty folders are intentional while the
first set is being composed: the synchroniser skips them and never removes an
existing App Store Connect set on their account.

## Local checks

### Logo and app icon

`assets/magpie-mark-transparent.png` is the approved logo master, a 1254 × 1254
PNG with real transparency. Its identical copy in
`ios/Hearful/Assets.xcassets/MagpieMark.imageset/` supplies the in-app artwork.
The previous traced SVG has been retired because it does not match this logo.

`ios/Hearful/Assets.xcassets/AppIcon.appiconset/icon-1024.png` uses the same
artwork, centred at 820 pixels wide on the existing `#101317` background. This
1024 × 1024 app icon is opaque; the logo master remains transparent.
`assets/magpie-mark-background-preview.png` previews the master on white and
dark backgrounds.

Apple takes the App Store icon from the uploaded app build; it is not a
separate listing upload. Updating the published icon requires a new app
version and review. See [Apple's app icon guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/add-an-app-icon/).

### Listing validation

Run this after editing any listing file or adding a screenshot:

```bash
make app-store-validate
```

The normal iOS build and CI release build run the same offline validation. It
checks Apple's length limits, required fields, screenshot dimensions, alpha
channels, count, and consistent sizing without contacting Apple.

To keep a screenshot of the screen currently shown in a simulator:

```bash
make app-store-fixtures
make app-store-backend  # leave running in a separate terminal

IOS_SIMULATOR_ID=<udid> \
  make app-store-screenshot \
  DISPLAY=APP_IPHONE_67 NAME=01-latest
```

The fixture command uses an isolated SQLite database under the ignored
`build/` directory, so it cannot alter the ordinary development database. It
rebuilds only that dedicated database with records under the reserved
`hearful.invalid` domain. It gives phone and iPad captures the same three
feeds, one followed email newsletter, one sender waiting for an answer, their
episodes and issues, three captured web pages in Saved, a newsletter address
and a listening position every time;
the app itself still fetches and renders them through its real backend and
production views. The backend target switches newsletters on with the real
inbound domain and an invented address, so the Settings screen shows the
shape she would be given without anything sent there arriving anywhere.

Debug builds open a named screen when launched with
`HEARFUL_SCREENSHOT_SCREEN`, so a capture never depends on injecting taps into
the simulator: `following`, `latest`, `settings`, `show:<id>` for a followed
show's page, or `article:<episode id>` for a piece open for reading, with the
ids being the ones the fixture backend hands out (`curl -H 'Authorization:
Bearer hearful-local-development' localhost:8000/feeds`). Release builds ignore
the variable.

```bash
xcrun simctl terminate <udid> com.henrydashwood.hearful
SIMCTL_CHILD_HEARFUL_SCREENSHOT_SCREEN=show:4 \
  xcrun simctl launch <udid> com.henrydashwood.hearful
```

Capture on the matching iPhone and iPad simulators. The command normalises the
status bar before capture and refuses an unknown display type or unsafe file
name. Review every image in the repository before uploading it: it must show
real app behaviour, contain no personal data, and remain accurate for the build
being released.

## App Store Connect sync

Signing, version selection, listing sync, review contacts, submission, and
recovery are maintained in the [mobile release guide](../docs/mobile-releases.md#ios).
That guide also covers Console-owned submission choices; this file covers
listing assets, authoring, and accessibility evidence.

## Accessibility declaration

*App Store Connect → App Accessibility.*

These notes record an earlier source review and outstanding device checks.
Recheck them on the current build before making store declarations.

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
