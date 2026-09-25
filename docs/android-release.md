# Android release preparation

Updated 17 September 2026. No Google Play Console account/app or release key exists
yet. These helpers prepare a build; they do not upload, publish, register OAuth
clients or modify production. The prototype version remains unchanged.

## Build setup prepared

- `make android-release-check` validates private signing inputs, HTTPS API origin,
  the Google server client ID shape, key access and the supplied SHA-1 fingerprint.
- `make android-release` runs that validation before building a signed release APK
  and Android App Bundle. Outputs are under `android/app/build/outputs/`.
- Release uses app ID `com.henrydashwood.magpie` and display name **Magpie**.
  Debug retains `.dev`, **Magpie Preview**, and its staging defaults.
- Release defaults to `https://audio-reader-production.up.railway.app` and the
  already configured public Google server client ID. Explicit Gradle properties
  `MAGPIE_ACCOUNT_API_URL` and `MAGPIE_GOOGLE_SERVER_CLIENT_ID` override these.
  Use the staging API override for acceptance before production promotion.

Supply the following Gradle properties through a private, untracked user Gradle
properties file or your secret manager/CI environment. Environment variables use
Gradle's `ORG_GRADLE_PROJECT_` prefix. Do not put keys/passwords in the repository,
command history, BuildConfig or PR descriptions.

| Property | Value |
| --- | --- |
| `MAGPIE_RELEASE_STORE_FILE` | Absolute path to the private keystore |
| `MAGPIE_RELEASE_STORE_PASSWORD` | Keystore password |
| `MAGPIE_RELEASE_KEY_ALIAS` | Signing key alias |
| `MAGPIE_RELEASE_KEY_PASSWORD` | Key password |
| `MAGPIE_RELEASE_OAUTH_SHA1` | SHA-1 certificate fingerprint, with or without colons |

The fingerprint check compares the local keystore with the operator-supplied
value. It **cannot verify remote Google OAuth registration**. Register the exact
package/certificate pair and test sign-in before claiming it is configured.
Play App Signing normally signs distributed APKs with a different key from the
upload key. Register the **Play app-signing certificate** for Play installs as
well as the local certificate if distributing locally signed APKs. See
[Google's signing documentation](https://developer.android.com/studio/publish/app-signing).
Never reuse the debug key as a release key.

- Release builds are shrunk and optimised by R8 (`app/proguard-rules.pro`). Upload
  `app/build/outputs/mapping/release/mapping.txt` with each bundle so Play can
  de-obfuscate crash reports. R8 only runs on release, so the debug test suite does
  not cover it: sign in and exercise playback, voice and saving on the
  internal-testing build before promoting it.
- Store graphics (512px icon, 1024×500 feature graphic) are in `play-store/graphics/`.

## Remaining release gates

- [ ] Create the Play Console account and Magpie app under the intended owner.
- [ ] Choose Play App Signing, create and securely back up an upload key, and store
  signing passwords outside Git. Record key ownership and recovery procedures.
- [ ] Register Android Google OAuth clients for the release package and relevant
  local/Play certificates. Confirm the shared web client/server audience.
- [ ] Verify production Apple Services ID, associated iOS App ID, callback/domain
  configuration and Google audience using [sign-in.md](sign-in.md). Configuration
  saved previously is not proof of a successful production sign-in.
- [ ] Merge tested code through normal review. Main CI deploys the backend to
  staging. Verify migrations, health, shared bookmarks and both clients there;
  promote that exact deployment with the manual production workflow described in
  [backend-releases.md](backend-releases.md). Do not enable Railway production
  push autodeploys or promote an unverified backend.
- [ ] Complete the applicable [acceptance matrix](android-acceptance.md), including
  linked-provider sign-in on an internal-test build signed by Google Play.
- [ ] Choose the release version/code, prepare screenshots/listing, privacy policy,
  data safety/account deletion disclosures, content rating and permission review.
  Recheck current Play requirements in the Console before submission. Drafts are in
  [`play-store/`](../play-store/README.md): listing text and
  [release notes](../play-store/release_notes/en-GB.txt),
  [Data safety](../play-store/data_safety.md), and the other
  [App content answers](../play-store/app_content.md) (access, content rating,
  foreground service, permissions, account deletion). Resolve their owner
  questions first.
- [ ] Build/inspect the signed APK/AAB, upload to internal testing, then obtain
  explicit release approval before publishing to users.

Do not tick signing, store, production or phone acceptance gates based on a debug
emulator build. Missing external setup should remain visible here.
