# Mobile releases

This is the canonical operating guide for Magpie mobile releases, used by the
[Magpie release skill](../.agents/skills/magpie-release/SKILL.md). The checked-in
workflows and scripts define the executable behaviour; recheck them if this
guide and the implementation disagree.

## Choose the destination

Distinguish preparation only, internal testing, external testing, and a public
store release. Use the user's request and existing session context; clarify
only when they leave materially different destinations open. An authorized
release request covers its necessary preparation, publication, and monitoring;
do not request the same approval again. A status question or documentation task
does not authorize a new upload or submission.

Release only the requested platforms and channels. Mobile publishing does not
authorize [backend production promotion](backend-releases.md), phone installs,
credential changes, or the other platform's release.

## Prepare and verify the sources

1. Follow [AGENTS.md](../AGENTS.md). Inspect the working tree, Git remote,
   remote `main`, tags, and recent release runs. Preserve unrelated changes.
2. Choose the version from current tags, release notes, successful workflow
   runs, and store state when available. Manual releases may be newer than the
   latest tag. Do not reuse a closed App Store version or uploaded build number.
3. Prepare the intended changes and user-facing notes. Run the checks required
   by `AGENTS.md`; commit only the intended files. Push to `main` when requested
   or otherwise authorized, without force-pushing or discarding parallel work.
4. Wait for the required CI results for the release sources. Record the exact
   commit SHA and verify each subsequent run's `headSha`. Create a tag only when
   the selected release route calls for one, pointing it at that SHA. Do not
   bypass tests or alter runtime pins merely to obtain a green release.

Both workflows calculate the build number/version code from
`git rev-list --count` of the release commit. They set the marketing version;
ordinary CI releases do not require changing Xcode or Gradle fallback version
fields. Do not make dummy commits to repeat an upload. Reuse the uploaded build
for distribution or submission retries.

In the examples below, determine `release_repo`, `release_version`,
`release_sha`, and any existing `release_build` from current state. Run commands
from the repository root. Examples are not permission to publish.

### Pinning a manual dispatch

GitHub's workflow dispatch takes a branch or tag, not an arbitrary commit SHA.
Use an existing immutable ref when its trigger and distribution semantics match
the requested destination. Do not create a `v*` tag just to pin an internal beta:
the tag push itself starts external distribution and public-draft sync.

When a route below uses mutable `main`, resolve the remote branch immediately
before dispatch and require it to equal `release_sha`. Locate the new run and
check its `headSha` as soon as it is created, before allowing signing/upload to
proceed. If it differs, cancel that run immediately and confirm cancellation;
re-establish the tested ref before retrying. If upload may already have started,
inspect store state rather than assuming cancellation prevented publication.
Do not dispatch while a known concurrent update makes the intended ref uncertain.

## iOS

### Sources and gates

- [testflight.yml](../.github/workflows/testflight.yml) owns signing, upload,
  distribution, and App Store sync. TestFlight releases are not automatic on
  every push to `main`.
- [ci.yml](../.github/workflows/ci.yml) and
  [ios-tests.yml](../.github/workflows/ios-tests.yml) own automatic validation.
  Both supported iOS generations must pass before a release can upload.
- [docs/CHANGELOG.md](CHANGELOG.md) supplies the topmost version section as
  TestFlight's What to Test and the public What's New text. Match the heading
  to the release version without `v`, and run `make app-store-validate`.
- [app-store/](../app-store/README.md) holds listing copy, review notes,
  screenshots, and their authoring/validation instructions.

`make ios-doctor` diagnoses the local toolchain. `make ios-test` and
`make ios-test-compatibility` run the suites. GitHub's shared self-hosted runner
may queue one generation behind the other. A completed test step can still be
followed by cache/artifact uploads; wait for the required final results.
The release workflow's `ci-coverage` job can reuse passing main CI for identical
iOS inputs, so let main CI finish before tagging.

### Internal TestFlight build

Dispatch on verified `main`, explicitly selecting the marketing version:

```sh
gh workflow run testflight.yml --repo "$release_repo" --ref main \
  -f build_version="$release_version"
```

Verify that the resulting run targets `release_sha`. The top changelog section
must match `build_version`. A manual run without that override inherits the
highest reachable `v*` tag, or falls back to the Xcode project before any tags
exist; this may be older than the latest manually released version.

Without distribution/sync inputs, the workflow uploads a build and sets its
notes for the internal group. It does not distribute externally or submit a
public App Store release.

For iOS, a dedicated release branch kept at the verified SHA can also pin a
manual dispatch without the side effects of pushing a `v*` tag. Use that route
when `main` cannot be kept stable, and still verify the branch and run SHA.
Android's release environment has stricter allowed refs, described below.

### External TestFlight only

After a successful upload, use the existing-build distribution path on the
appropriate verified branch:

```sh
gh workflow run testflight.yml --repo "$release_repo" --ref main \
  -f distribute_build="$release_build"
```

Check the ref, notes, version, and run SHA before dispatching, especially if
`main` has advanced since the build. This uses the existing **Friends and
Family** group and can submit **Beta App Review**. Omit `sync_version` and
`submit_for_review` for a strictly TestFlight-only request. Do not use a tag ref
without accounting for the additional public-draft sync described below.

External testers see a build only after Beta App Review approves it. An internal
group configured to receive every build sees it after processing finishes.

### Tagged release

Once the intended sources are on `main` and CI has passed, tag the exact SHA:

```sh
release_ref="v$release_version"
git tag -a "$release_ref" "$release_sha" -m "Magpie $release_version"
git push origin "refs/tags/$release_ref"
```

The tag starts `testflight.yml`, sets the marketing version, uploads the
commit-count build, distributes to Friends and Family, syncs the public draft
listing, and selects that build. **A successful tagged run does not itself
submit the public version for App Review.** Beta App Review may remain pending
even when the workflow succeeds.

Find the run by tag, verify its `headSha`, and read the distribution result to
confirm the actual build number and processing/review state.

### Complete a public App Store release

For an authorized public release, after upload/distribution succeeds, dispatch
the existing-build path with public review enabled. For a tagged release, use
the same tag so this follow-up uses the same scripts and release notes.

If promoting an already uploaded internal build **without an existing release
tag**, set `release_ref` to a matching verified branch (which may be a dedicated
iOS release branch) and use the same existing-build dispatch below. Do not push
a new tag merely to submit that build: it would trigger another upload of the
already-used build number. Apply the manual-dispatch source checks above and
ensure that the branch has the intended version's release notes.

```sh
gh workflow run testflight.yml --repo "$release_repo" --ref "$release_ref" \
  -f distribute_build="$release_build" \
  -f sync_version="$release_version" \
  -f submit_for_review=true
```

Follow this run to completion. Confirm the intended build is selected and the
intended version was submitted, or is already in review. The release type comes
from [app-store/config.json](../app-store/config.json): `AFTER_APPROVAL` schedules
automatic release after Apple approves it. Report review pending until
approval/availability is separately verified.

### Store state and recovery

When App Store credentials are already available, inspect the API's state with:

```sh
uv run scripts/app_store_sync.py status
```

This reports versions and selected builds, review submissions, recent builds
and beta review states, and the groups that can see them. A withdrawn review
can remain `CANCELING` until Apple finishes the transition.

If an **internal-only** upload succeeded but its notes/distribution job failed,
rerun only that failed job in the original internal run, preserving its original
inputs. Find the run and failed distribution job IDs, then:

```sh
gh run rerun "$release_run" --repo "$release_repo" --job "$failed_distribution_job"
```

Do not rerun the successful build job. Do not switch this recovery to a new
`distribute_build` dispatch: that input always adds Friends and Family, even
when `sync_version` is omitted. With existing credentials, the local notes-only
path omits `--external-group`; use a matching release checkout and version:

```sh
uv run scripts/testflight_distribute.py --build-number "$release_build" \
  --expect-version "$release_version" --changelog docs/CHANGELOG.md
```

For **authorized external distribution or public submission**, reuse
`distribute_build` with the same known version/build/ref and only the inputs
needed for the remaining stages. Do not rebuild the same commit: Apple rejects
a build number it has already received. Inspect current state before retrying a
mutation that may already have succeeded. An in-flight public version can
prevent creating another; report that condition rather than withdrawing it as
an incidental workaround.

[scripts/app_store_sync.py](../scripts/app_store_sync.py) can sync locally with
`sync --version "$release_version"`, optionally `--select-build`,
`--review-notes`, and `--submit`. `--dry-run` reads the proposed changes without
writing. Its `testflight` command syncs beta descriptions and, when requested,
review details. Prefer the workflow for a routine release.

Sync creates the version if needed or retargets one editable draft. Screenshot
sets are replaced only when ordered filenames/checksums differ; empty sets do
not erase existing remote screenshots. A successful sync alone is not a review
submission.

### Signing and App Store credentials

Reuse the configured repository secrets. This table documents their purpose;
it does not authorize creating or replacing them.

| Repository secret | Purpose |
| --- | --- |
| `APPLE_DISTRIBUTION_CERT_P12` | Base64-encoded Apple Distribution certificate and private key exported as `.p12` |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | Password for that `.p12` |
| `APPLE_PROVISIONING_PROFILE` | Base64 App Store profile for `com.henrydashwood.hearful` |
| `APPLE_CONTROLS_PROVISIONING_PROFILE` | Profile for `com.henrydashwood.hearful.controls` |
| `APPLE_SHARE_PROVISIONING_PROFILE` | Profile for `com.henrydashwood.hearful.share` |
| `APPLE_BACKGROUND_ASSETS_PROVISIONING_PROFILE` | Profile for `com.henrydashwood.hearful.BackgroundAssets` |
| `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_P8` | Team App Manager API key; `.p8` is base64-encoded |
| `APP_STORE_CONNECT_INDIVIDUAL_KEY_ID`, `APP_STORE_CONNECT_INDIVIDUAL_KEY_P8` | Optional individual API key; review submissions/listing sync use the person's identity when configured |
| `ASC_REVIEW_CONTACT_FIRST_NAME`, `ASC_REVIEW_CONTACT_LAST_NAME`, `ASC_REVIEW_CONTACT_EMAIL`, `ASC_REVIEW_CONTACT_PHONE` | Optional private contact, configured as a complete set; enables review contact/notes sync |

CI signing is **manual**, even though local builds use automatic signing. It
uses a real exported Distribution certificate/private key and profiles that
include that certificate. A cloud-managed certificate from an earlier Xcode
upload does not provide an exportable private key. Giving the archive API-key
access plus `-allowProvisioningUpdates` can create a Development identity and
fail later at distribution export; do not replace the workflow's manual setup
with that workaround.

Profiles must match each target's entitlements. The app, share extension, and
Background Assets extension use `group.com.henrydashwood.hearful`. Regenerate
affected profiles when their certificate or entitlements change, and check
actual expiry dates when diagnosing signing failures. Do not rely on a date in
an old release note.

The workflow rewrites profile UUIDs into a copy of `ios/ExportOptions.plist`;
`xcodebuild -exportArchive` uploads directly without a separate Transporter step.
Distribution runs separately on Linux through
[scripts/testflight_distribute.py](../scripts/testflight_distribute.py), allowing
recovery without another signed build. CI cleans up temporary signing material.

For local API calls, the equivalent team variables are `ASC_KEY_ID`,
`ASC_ISSUER_ID`, and `ASC_KEY_P8_BASE64`. `ASC_INDIVIDUAL_KEY_ID` and
`ASC_INDIVIDUAL_KEY_P8_BASE64` take precedence for sync/review when present;
individual keys have no issuer ID. Local review contact uses the same four
`ASC_REVIEW_CONTACT_*` names with `--review-notes`. Keep values out of Git,
command history, logs, and build configuration. Missing credentials are not a
reason to recreate keys or expand permissions during a release.

### Store choices outside repository sync

When relevant to the release, verify the Console-owned choices: categories,
age rating/content rights, privacy answers against the privacy manifest/policy,
[accessibility declarations and device evidence](../app-store/README.md#accessibility-declaration),
price/territories/agreements, export compliance, selected build and release mode,
and the accuracy of phone/iPad screenshots. Do not infer these from a green sync.

## Android

### Sources, checks, and versions

[play-release.yml](../.github/workflows/play-release.yml) is the supported CI
path. Follow [android/AGENTS.md](../android/AGENTS.md) and the
[development/test instructions](../android/README.md). Run `make android-check`;
for UI/service changes, run the applicable `make android-test` checks. Report
emulator coverage separately from physical-phone, TalkBack, Bluetooth, offline
voice, and Play-signed acceptance.

Inspect existing `android-v*` tags and recent Google Play runs before choosing
the version. Update `play-store/release_notes/<language>.txt`; these notes and
versions are independent of the iOS changelog. The workflow sets `versionCode`
from the commit count and `versionName` from the tag, or the highest reachable
Android tag for a manual run. Before any tags it uses the Gradle fallback.
Verify the resulting name/code in the upload logs. A local fallback code can be
lower than one already released by CI and will be rejected by Play.

### Publish to a testing track

The workflow supports **internal** and closed testing (**alpha**) only; its
account is restricted to testing releases. A new tagged version uses internal
testing by default:

```sh
release_ref="android-v$release_version"
git tag -a "$release_ref" "$release_sha" -m "Magpie Android $release_version"
git push origin "refs/tags/$release_ref"
```

For a manual run, use verified `main` or an allowed Android tag and select the
authorized track and draft state:

```sh
gh workflow run play-release.yml --repo "$release_repo" --ref main \
  -f track=alpha -f draft=false
```

Verify the resulting run's `headSha`. Choosing alpha does not create a different
version code: this workflow always uploads a bundle, so use it only for a new,
unused code. To promote an already uploaded internal build to alpha, inspect the
existing release in Play Console and use its promotion path; rerunning this
workflow at the same commit would attempt a duplicate upload. Use `draft=true`
only when requested or required by the current Play app state; historical
first-review notes do not establish today's state.

The workflow checks, builds/signs, authenticates through Google workload
identity, and uploads the bundle, R8 mapping, release notes, and track
assignment in a committed Play edit. Retained artifacts include the AAB and
mapping. Follow the edit through completion and report version name/code,
commit, track, draft/rollout status, and run link. A testing upload is not a
public release or proof of physical-device acceptance.

If upload fails, establish whether the edit committed and the version code
already exists before retrying. Inspect [scripts/play_upload.py](../scripts/play_upload.py)
and current Play state; do not blindly rerun after a partial success or invent a
commit solely to get a new code. For a production request, inspect the current
promotion process and authorization; do not expand CI permissions or remove
workflow track restrictions to turn a testing upload into production.

The tagged internal upload and manual alpha upload above are alternative paths
for an unused code, not consecutive steps for the same commit. The current
workflow has no `build_version` override for a new alpha marketing version;
do not push an Android tag and then attempt another alpha upload of that code.

### Signing and configuration

The GitHub environment `play-release` is restricted to `main` and `android-v*`
tags. It uses existing upload-key material and Google workload identity
federation, without a stored Play service-account JSON key.

| Environment setting | Purpose |
| --- | --- |
| Secret `MAGPIE_UPLOAD_KEYSTORE_BASE64` | Base64 upload keystore |
| Secrets `MAGPIE_RELEASE_STORE_PASSWORD`, `MAGPIE_RELEASE_KEY_PASSWORD` | Keystore/key passwords |
| Variables `MAGPIE_RELEASE_KEY_ALIAS`, `MAGPIE_RELEASE_OAUTH_SHA1` | Upload alias and expected signing fingerprint |
| Variables `GCP_WORKLOAD_IDENTITY_PROVIDER`, `PLAY_SERVICE_ACCOUNT` | Existing federated provider and Play testing account |

The federation setup record is project `magpie-508316` (number
`102154849961`), pool `github`, provider `audio-reader`, and service account
`play-uploader@magpie-508316.iam.gserviceaccount.com`. The recorded provider name
is `projects/102154849961/locations/global/workloadIdentityPools/github/providers/audio-reader`.
Required APIs include Android Publisher, IAM Credentials, and Security Token
Service (`androidpublisher.googleapis.com`, `iamcredentials.googleapis.com`,
`sts.googleapis.com`). Verify current state before repairing configuration:

```sh
gcloud iam workload-identity-pools providers describe audio-reader \
  --project=magpie-508316 --location=global --workload-identity-pool=github
gcloud iam service-accounts get-iam-policy \
  play-uploader@magpie-508316.iam.gserviceaccount.com --project=magpie-508316
```

The recorded issuer is `https://token.actions.githubusercontent.com`, with
attribute mappings `google.subject=assertion.sub`,
`attribute.repository=assertion.repository`, and `attribute.ref=assertion.ref`.
Its condition limits the repository and ref:

```text
assertion.repository=='HenryDashwood/audio-reader' && (assertion.ref=='refs/heads/main' || assertion.ref.startsWith('refs/tags/android-v'))
```

The service account's `roles/iam.workloadIdentityUser` binding uses principal
`principalSet://iam.googleapis.com/projects/102154849961/locations/global/workloadIdentityPools/github/attribute.repository/HenryDashwood/audio-reader`.
The GitHub environment's variables and the live Google policy take precedence
over this recovery record; these are inspection details, not instructions to
recreate the provider, broaden its trust, or change Play permissions.

Release uses package `com.henrydashwood.magpie`, display name Magpie, and the
production API by default. Debug uses `.dev`, Magpie Preview, and staging. See
[sign-in](sign-in.md) for Google/Apple configuration and acceptance. Register the
actual package/certificate pair: Play App Signing can use a different certificate
from the upload key. A local fingerprint check cannot prove remote OAuth setup
or successful sign-in on a Play-distributed build. Do not use the debug key for
release signing or create a service-account key to bypass federated auth.

### Intentional local release work

Prefer CI for store uploads. For an explicitly requested local signed build,
`make android-release-check` validates signing inputs and
`make android-release` produces the signed APK/AAB under
`android/app/build/outputs/`. Private settings are loaded from
`~/.gradle/gradle.properties`, or `MAGPIE_RELEASE_PROPERTIES`, and passed as
`ORG_GRADLE_PROJECT_` variables rather than command-line passwords:

| Gradle property | Value |
| --- | --- |
| `MAGPIE_RELEASE_STORE_FILE` | Private keystore path |
| `MAGPIE_RELEASE_STORE_PASSWORD` | Keystore password |
| `MAGPIE_RELEASE_KEY_ALIAS` | Key alias |
| `MAGPIE_RELEASE_KEY_PASSWORD` | Key password |
| `MAGPIE_RELEASE_OAUTH_SHA1` | Expected SHA-1 certificate fingerprint |

`MAGPIE_ACCOUNT_API_URL` and `MAGPIE_GOOGLE_SERVER_CLIENT_ID` override the release
server/audience. Keep signing inputs outside Git and BuildConfig. Do not change
the production destination as an incidental build workaround.

`make android-upload` uploads the prepared bundle, mapping and notes. It defaults
to internal testing; `TRACK=alpha` selects closed testing, and `DRAFT=1` leaves a
draft. The local helper also has a production path guarded by
`PLAY_ARGS=--confirm-production` and supports staged `--rollout`; its existence
does not authorize production or establish that the current account may use it.
Use only the destination requested by the user and verified in current Play state.

Local API auth can use an existing `MAGPIE_PLAY_ACCESS_TOKEN`, or the credential
sources documented in `scripts/play_upload.py` (`MAGPIE_PLAY_SERVICE_ACCOUNT`,
`MAGPIE_PLAY_SERVICE_ACCOUNT_JSON`, or its default private key path). Routine CI
uses a short-lived federated token instead. Do not copy private keys into the repo.

R8 runs only for release, so debug checks do not cover shrinker behaviour.
Preserve the mapping file and perform the applicable
[acceptance checks](android-acceptance.md) on the Play-signed build before
broader promotion. Listing copy, graphics, and Console-owned privacy/content
answers remain in [play-store/](../play-store/README.md); resolve relevant
owner decisions there without claiming they were checked by an emulator run.

## Monitoring, retries, and the final report

Follow the selected workflow through the requested terminal stage, including
processing, distribution, metadata sync, and submission where applicable. A
successful archive alone is not a completed release. Use bounded waits and
concise updates as stages change; do not create an automation to watch one run.

Inspect failures before retrying. A targeted retry can address a diagnosed
transient failure. Repeated identical failures, signing/auth errors, store
rejections, or uncertain publication state require investigation rather than
blind uploads. Reuse existing credentials. Do not move a published tag,
withdraw a review, or bypass gates as an incidental recovery step.

Report the version, build/code, exact commit, relevant checks, and workflow link.
Separate compiler warnings from test failures. Distinguish uploaded, waiting for
beta review, submitted for public review, and actually available. Store review
may remain pending after the requested submission has succeeded.
