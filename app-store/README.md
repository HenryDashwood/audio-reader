# App Store listing

This directory is the source of truth for Hearful's public App Store listing.
Do not make a lasting copy change only in App Store Connect: make it here, let
CI validate it, and sync it from a release tag.

## What is kept here

- `config.json` identifies the app and holds non-localised version settings.
- `metadata/<locale>/` contains one plain-text field per App Store field.
- `review_notes.txt` is the non-public explanation for App Review. Contact
  details are deliberately not committed.
- `screenshots/<locale>/<display type>/` contains the final ordered images.
  Filenames sort into their storefront order, so use names such as
  `01-latest.jpg`, `02-shows.jpg`, and `03-player.jpg`.

The current screenshot folders cover both device families the Xcode target
supports:

- `APP_IPHONE_69`: a 6.9-inch iPhone screenshot. The preferred simulator is an
  iPhone 17 Pro Max, whose portrait output is 1320 × 2868.
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
  DISPLAY=APP_IPHONE_69 NAME=01-latest
```

The fixture command uses an isolated SQLite database under the ignored
`build/` directory, so it cannot alter the ordinary development database. It
rebuilds only that dedicated database with records under the reserved
`hearful.invalid` domain. It gives phone and iPad captures the same three shows,
six episodes and listening position every time; the app itself still fetches
and renders them through its real backend and production views.

Capture on the matching iPhone and iPad simulators. The command normalises the
status bar before capture and refuses an unknown display type or unsafe file
name. Review every image in the repository before uploading it: it must show
real app behaviour, contain no personal data, and remain accurate for the build
being released.

## App Store Connect sync

A `v*` release tag validates and uploads the app name, subtitle, privacy URL,
version description, keywords, promotional text, support URL, copyright, and
any non-empty screenshot sets. It creates the iOS App Store version when it is
not already present. It does **not** submit the version for review or release
it; those remain explicit decisions in App Store Connect.

The same operation can be run locally:

```bash
ASC_KEY_ID=... \
ASC_ISSUER_ID=... \
ASC_KEY_P8_BASE64=... \
  uv run scripts/app_store_sync.py sync --version 1.0
```

Use `--dry-run` with those credentials to inspect the remote plan without
writing. Screenshot sets are only replaced when their ordered file names and
checksums differ. An API key with the App Manager role is required.

Review notes are stored here but are not uploaded by CI because Apple's review
record also contains a private phone number. To sync them, set the four contact
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
- export-compliance answers, the selected build, release mode, and review
  contact details;
- every screenshot on both phone and iPad, at full size.

The synchroniser intentionally does not submit for review. A successful upload
means the listing is in sync, not that the version is ready to publish.
