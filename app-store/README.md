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
episodes and issues, a newsletter address and a listening position every time;
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

A `v*` release tag validates and uploads the app name, subtitle, privacy URL,
version description, keywords, promotional text, support URL, copyright, and
any non-empty screenshot sets, and selects the build it has just distributed.
It creates the iOS App Store version when it is not already present, or renames
the one editable draft (never submitted, or sent back by review) to the new
version. It does **not** submit the version for review on its own: that is a
manual run of the workflow with **submit_for_review** ticked, alongside the
build number and version, which sends the version to App Review with the
repository's notes and contact. Releasing an approved version stays a decision
made in App Store Connect.

The same operation can be run locally:

```bash
ASC_KEY_ID=... \
ASC_ISSUER_ID=... \
ASC_KEY_P8_BASE64=... \
  uv run scripts/app_store_sync.py sync --version 1.0
```

Add `--select-build <number>` to pick a processed build for the version, and
`--submit` to send it to App Review once everything is in sync. Use `--dry-run`
with those credentials to inspect the remote plan without writing. To see what App Store Connect itself believes, which the web page
sometimes puts in friendlier words and occasionally different ones:

```bash
uv run scripts/app_store_sync.py status
```

It prints every App Store version with its API state and selected build,
the review submissions and theirs (a withdrawal shows as `CANCELING` until
it lands), the newest builds with their beta review state, and each beta
group with its tester count and the builds it can see. An external group
sees a build only once beta review has approved it; an internal group set
to receive every build sees it as soon as processing finishes. Screenshot sets are only replaced when their ordered file names and
checksums differ. An API key with the App Manager role is required.

Every distributed build, tagged or not, also syncs the TestFlight test
information: the beta app description, and with the contact set, Beta App
Review's contact and notes. The same operation is:

```bash
uv run scripts/app_store_sync.py testflight [--review-notes] [--dry-run]
```

Both commands sign with the individual API key in `ASC_INDIVIDUAL_KEY_ID` and
`ASC_INDIVIDUAL_KEY_P8_BASE64` when those are set, so what they submit shows
under a person's name in App Store Connect, and fall back to the team key.

Apple's review record also contains a private phone number, so the contact is
never committed. CI writes the review notes only when the four
`ASC_REVIEW_CONTACT_*` repository secrets exist; locally, set the same four
variables and opt in:

```bash
ASC_REVIEW_CONTACT_FIRST_NAME=... \
ASC_REVIEW_CONTACT_LAST_NAME=... \
ASC_REVIEW_CONTACT_EMAIL=... \
ASC_REVIEW_CONTACT_PHONE=... \
  uv run scripts/app_store_sync.py sync --version 1.0 --review-notes
```

## Still completed in App Store Connect

Some submission choices are questionnaires or commercial decisions rather
than repository copy. Before submitting a version, check these manually:

- primary and secondary categories;
- age rating and content-rights declarations;
- app privacy answers against `ios/Hearful/PrivacyInfo.xcprivacy` and the
  public privacy policy;
- App Accessibility declarations against the device pass in
  `docs/store-listing.md`;
- price, territories, tax and banking agreements;
- export-compliance answers, the selected build, and release mode;
- every screenshot on both phone and iPad, at full size.

A successful sync means the listing is in sync, not that the version has been
submitted: that takes the explicit `submit_for_review` run described above.
