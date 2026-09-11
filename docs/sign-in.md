# Apple, Google, and linked accounts

Apple and Google sign-in are implemented on iOS and Android. iOS keeps its native
Apple sheet; Android opens Apple's authorization page in a browser Custom Tab.
A person signed in to Magpie can connect another provider by authenticating with
it in Settings → Sign-in Methods. Both identities then resolve to the same user
ID, library, listening progress, and consent choice. Linking does not grant AI
consent or copy/move any library data.

Android loads the signed-in account library and uses samples only while signed
out. It never uploads sample content or local article narration bookmarks. Android's Apple browser
flow is implemented; account-backed library loading remains unfinished in parity
item 1. Existing iOS Apple users can sign in directly with Apple on Android once
the configured backend has been deployed and the acceptance checks below pass.

## Provider configuration

Provider registrations and public Railway settings were configured on 11 September
2026. Commit `f82ae3c87bd17abc64c1ceed2d245ce8df460a06` passed main CI and
was deployed to staging. After enabling staging's Apple credentials, deployment
`488f5572-6b95-4a3a-89de-7ab597ef5190` succeeded with that same revision.
Production has not been redeployed or promoted. Existing native Apple sign-in
works independently of the browser configuration.

| Registration | Saved value |
| --- | --- |
| Apple Services ID | `com.henrydashwood.magpie.signin` (Magpie Sign In) |
| Associated primary App ID | `67F2439F4X.com.henrydashwood.hearful` |
| Google Cloud project | `magpie-508316` (Magpie) |
| Server Google client | `102154849961-o07dgdc8ltoescp4p3k9knl8rlm1l4m7.apps.googleusercontent.com` |
| iOS Google client | `102154849961-qfipdjtga90po55ge81gej1jkcahaj8h.apps.googleusercontent.com` |
| Android debug Google client | `102154849961-ail49srpfbg4g7kchpq8eo87vqk1uk1n.apps.googleusercontent.com` |
| Debug package | `com.henrydashwood.magpie.dev` |
| Registered debug SHA-1 | `34:61:3E:7B:CB:1F:29:15:05:90:66:58:F1:FE:15:7E:10:10:37:7C` |

Apple's saved website configuration includes both Railway domains and these
exact return URLs:

- `https://audio-reader-staging.up.railway.app/auth/apple/browser/callback`
- `https://audio-reader-production.up.railway.app/auth/apple/browser/callback`

Both Railway environments have the Services ID, their corresponding callback,
and the server Google client ID saved with deployment skipped. Production's
existing Apple key and encryption settings were preserved. Staging now has the
Apple signing credentials and its own separate generated Fernet encryption key.
The saved staging revocation setting remains `false`. No production credentials
were changed.

Google is External / Testing with `hcndashwood@gmail.com` registered as a test
user. Branding uses Magpie, that support/contact address, the existing production
`/support` and `/privacy` pages, and the authorised domain
`audio-reader-production.up.railway.app`. The consent scopes are limited to
`openid`, email, and profile. No mobile app uses a Google client
secret. Android release registration awaits an actual release signing certificate;
none existed when configuration was performed. Other development machines need
their own debug certificate registered.

### Apple on Android

In Apple Developer, configure a Services ID for Sign in with Apple and associate
it with the existing iOS app's primary App ID. That association is essential:
Apple must issue the same user subject to both clients so an existing library
is reached rather than a separate account being created. Follow Apple's
[other-platform setup](https://developer.apple.com/documentation/signinwithapple/incorporating-sign-in-with-apple-into-other-platforms)
and [app grouping instructions](https://developer.apple.com/help/account/capabilities/group-apps-for-sign-in-with-apple).
Register the backend domain and the exact public HTTPS return URL ending in
`/auth/apple/browser/callback`. The callback is hosted by the backend, not Android.

| Backend configuration | Value |
| --- | --- |
| `AUDIOREADER_APPLE_SERVICES_ID` | Associated Services ID, distinct from the native bundle ID |
| `AUDIOREADER_APPLE_BROWSER_REDIRECT_URI` | Registered HTTPS callback URL |
| `AUDIOREADER_APPLE_TEAM_ID` | Existing Apple developer team ID |
| `AUDIOREADER_APPLE_KEY_ID` | Sign in with Apple key ID for the primary app |
| `AUDIOREADER_APPLE_PRIVATE_KEY` | Corresponding private `.p8` key; backend only |
| `AUDIOREADER_APPLE_TOKEN_ENCRYPTION_KEY` | Environment-specific Fernet key for encrypted Apple grants and temporary codes |
| `AUDIOREADER_APPLE_REVOKE_ON_ACCOUNT_DELETION` | `true` in production (default); `false` in staging |

Keep the existing native `AUDIOREADER_APPLE_BUNDLE_ID` unchanged. Android needs
only `MAGPIE_ACCOUNT_API_URL` for Apple; Google configuration is independent.
The browser callback offers a Return to Magpie link using the allowlisted release
or debug app scheme. No Apple code, identity token, or Magpie session appears in
that return URL. Apply migration `f83a2c04d917` through the normal release process
before using the new endpoints.

Staging rollout order (steps 1–2 completed on 11 September 2026):

1. Deploy this backend through normal CI, including the migration and
   `apple_revoke_on_account_deletion` guard. The staging Railway setting
   `AUDIOREADER_APPLE_REVOKE_ON_ACCOUNT_DELETION=false` is already saved.
2. Verify that the deployed revision includes the guard before giving staging
   the Apple team ID, key ID, and private key needed for code exchange. Use a
   separate newly generated Fernet encryption key for staging. Keep all secrets
   out of source control and logs.
3. Staging was redeployed with those secrets. Complete real provider/linking checks.
   Deleting a staging account must remove its local identities without revoking
   the shared Apple app authorization used in production.
4. Promote the verified staging revision through the manual production workflow
   when production deployment is authorised. Production retains revocation.

Do not populate staging's Apple key before deploying the guard, or roll staging
back to a version without the guard while the key remains configured.

### Google on both platforms

Use one Google Cloud project with a web/server OAuth client, an iOS OAuth client
for `com.henrydashwood.hearful`, and Android OAuth clients matching the exact
package and signing certificate of each intended build. The debug package is
`com.henrydashwood.magpie.dev`; do not change release signing to match a debug
registration. Google's documentation covers [Android Credential Manager](https://developer.android.com/identity/sign-in/credential-manager-siwg-implementation)
and [iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating).

| Component | Configuration | Value |
| --- | --- | --- |
| Backend | `AUDIOREADER_GOOGLE_CLIENT_ID` | Web/server OAuth client ID |
| iOS build setting | `GOOGLE_SERVER_CLIENT_ID` | The same web/server client ID |
| iOS build setting | `GOOGLE_IOS_CLIENT_ID` | iOS OAuth client ID |
| iOS build setting | `GOOGLE_REVERSED_CLIENT_ID` | Reversed iOS client ID URL scheme |
| Android Gradle property | `MAGPIE_GOOGLE_SERVER_CLIENT_ID` | The same web/server client ID |
| Android Gradle property | `MAGPIE_ACCOUNT_API_URL` | HTTPS backend origin, without a path |

The iOS settings populate `GIDClientID`, `GIDServerClientID`, and the callback URL
scheme in Info.plist. Both Debug and Release project settings contain the
registered public client IDs. The callback is
`com.googleusercontent.apps.102154849961-qfipdjtga90po55ge81gej1jkcahaj8h`.
Google’s SDK is pinned in Package.resolved.

Android properties may be passed with `-P` to Gradle or set in a local Gradle
properties file. The repository helper also inherits Gradle's standard
`ORG_GRADLE_PROJECT_MAGPIE_GOOGLE_SERVER_CLIENT_ID` and
`ORG_GRADLE_PROJECT_MAGPIE_ACCOUNT_API_URL` environment variables. Client IDs are
public identifiers; no Google client secret belongs in either mobile app.
Debug builds default to the registered server client and the staging origin.
Explicit properties (including empty values) override those defaults. Release
builds retain empty defaults until a release certificate is registered and the
intended backend is supplied. No release signing configuration was changed.

Deploy through the existing staging and manual production promotion process in
[backend releases](backend-releases.md), after configuring the chosen environment.
Do not send test sign-in attempts to production as part of local verification.

## Additive API contract

| Request | Authentication | Response |
| --- | --- | --- |
| `POST /auth/google` | Google `identity_token` in JSON | Existing `{token, user}` session response |
| `GET /me/identities` | Magpie bearer session | `{providers: ["apple", "google"]}` (actual linked providers only) |
| `POST /me/identities/google` | Magpie bearer session + Google `identity_token` | Linked providers |
| `POST /me/identities/apple` | Magpie bearer session + Apple `identity_token`, optional `authorization_code` | Linked providers |
| `POST /auth/apple/browser/start` | SHA-256 completion challenge, `login`/`link` purpose, allowlisted return scheme; bearer required for linking | State, Apple authorization URL, 300-second expiry |
| `POST /auth/apple/browser/callback` | Apple's form POST with state and authorization code or error | Static return-to-app page |
| `POST /auth/apple/browser/complete` | State and private completion verifier; original bearer required for linking | Pending, cancelled, or completed session/provider list |
| `POST /auth/apple/browser/cancel` | State and private completion verifier | 204 |

Existing Apple login, session, library, logout, and deletion contracts are
unchanged. Migration `f83a2c04d917` adds short-lived browser handoffs and a nullable
client ID for Apple refresh grants. Existing identities are preserved; their
grants default to the native bundle ID. Frozen released-client sources remain
unchanged.

The browser handoff lasts five minutes and is stored in the database so callbacks
and app polling can reach different backend workers. Apple tokens are verified
against the Services ID audience and a fresh nonce. Completion requires a private
random verifier retained in Android Keystore-encrypted storage; only its SHA-256
challenge is sent when starting the flow, and the verifier never enters the browser.
Linking is also bound to the
exact initiating Magpie session, checked again after Apple's response. Returning
from the browser opens Sign-in Methods and resumes checking the retained private
proof; it cannot supply credentials. If a background check failed, foregrounding
the account screen retries it without reopening Apple. An in-flight check finishes
before the retry begins, so completion requests do not race.
Pending attempts survive app recreation, can be cancelled, and expire. Each
completed handoff is consumed once. If the final response is lost, start a fresh
attempt. Expired rows are reclaimed when another browser flow starts. Temporary
authorization codes are encrypted and validation telemetry excludes proof inputs.

Google tokens are checked against Google's signing keys, RS256, issuer, the
configured server audience, required timestamps and subject. Email is optional
metadata, never an account lookup or linking key. The backend does not obtain
Google API refresh tokens. Android encrypts Magpie sessions with Keystore; iOS
uses its existing Keychain store. Neither client stores Google ID tokens as its
Magpie session.

A link to the same Magpie account is idempotent. A provider identity already
attached to another account returns 409 and does not move it. Invalid additional
provider proof returns 400 so it does not revoke a valid Magpie session; an
invalid Magpie session returns 401. Signing in separately with two previously
unlinked identities creates two accounts, even if the email matches. Combining
already separate libraries is not implemented by the linking endpoint.

Account deletion removes every linked identity and Magpie session. Apple grants
are revoked using the existing encrypted refresh-token mechanism when available,
with the native App ID or Services ID that issued the stored grant.
Google sign-out clears the local provider credential state; no Google mail,
Drive, contacts, or offline API access is requested.

## Acceptance checks after configuration

1. On iOS, sign in with an existing Apple account containing saved content.
2. Connect Google in Settings → Sign-in Methods. Check that both show Connected.
3. Sign out and sign in with Google on iOS. Verify the same library, user ID,
   listening progress, and AI consent choice.
4. Sign in with Apple directly on Android, then repeat with that Google account.
   Check the same account ID, provider list, subscriptions, and saved articles.
   Signed-out sample content and local capture inboxes must remain separate. Verify the Services ID grouping with a real existing
   iOS account before enabling Android sign-in.
5. Start with a new Google account on Android, connect Apple, and sign in with
   Apple on both platforms. Repeat linking from iOS. During Android authorization,
   return using the callback link, background/reopen the app, and recreate its
   process. Check cancellation, expiry, offline retry, and a second browser return.
6. Cancel each provider sheet. Check that account state is unchanged. Try an
   identity already attached to another test account; check that neither library
   moves and the conflict is explained.
7. Reopen both apps, test offline restoration and server-revoked sessions, then
   delete a disposable linked account and verify both methods lose access to it.
8. Check VoiceOver, TalkBack, large text, dark mode, and device account selection
   on physical devices. Simulator and mock tests cannot validate provider setup.

## Local verification — 11 September 2026

- `make backend-check`: 978 backend tests and 96 repository-script tests passed;
  lint, formatting, and type checks passed.
- `make backend-compatibility`: all 21 frozen v1.4.1 contract scenarios passed.
- `make ios-build` and `make ios-test`: passed on iOS 26.5; 549 tests passed,
  with the opt-in recording benchmark skipped. No compiler warnings reported.
- The full suite also passed on iOS 27 through XcodeBuildMCP: 549 passed,
  0 failed, 1 optional benchmark skipped. Two `make ios-test-latest` attempts
  stalled after the test host exited, while Xcode was collecting diagnostics.
  The successful run used `-collect-test-diagnostics never` and a 60-second
  test allowance; no tests were excluded or failures suppressed.
- `make android-check`: both debug APKs built, all 41 JVM tests passed, lint
  passed. No application compiler warnings or lint issues were reported.
- After configuration, the full Android 16/API 36 emulator suite passed all
  48 tests with zero failures or skips, including account controls, encrypted
  handoffs, cold/warm Apple browser return, and activity recreation. The preview
  was reinstalled and launched successfully without clearing its data.

After provider configuration, `make backend-check`, `make backend-compatibility`,
`make ios-build`, `make ios-test`, and `make android-check` passed again. The built
iOS Info.plist and Android BuildConfig contain the registered IDs and expected
callback/server settings. No compiler warnings were reported.

Real Apple browser authorization and code exchange now pass on staging, as
detailed below. Native Android Google authorization has also succeeded with a
real account. Android linking and switching from Apple to Google have now passed;
iOS Google acceptance remains pending.
Full provider acceptance, production backend rollout, Google production audience
publication, Android release registration, and physical-device accessibility
acceptance remain required before releasing these sign-in flows.

The final Android account screen was opened through the real browser return link
and inspected visually on the emulator. Both provider buttons, setup messages,
existing-Apple-account instructions, and sample-library disclosure were visible
without clipping at the emulator's current text size. The original unconfigured preview kept both
buttons disabled. Debug builds now contain the registered development settings;
staging now supports sign-in; production rollout remains pending.

## Live staging verification — 11 September 2026

Deployment `488f5572-6b95-4a3a-89de-7ab597ef5190` reached `SUCCESS` after the
credential update. Health, Apple browser start, configured Services ID/callback,
wrong-proof rejection, pending status, cancellation, replay rejection, callback
cancellation, Google invalid-token rejection, and unauthenticated identity access
checks passed against the live staging API. Temporary test handoffs were consumed
or cancelled. These checks created no accounts and did not access production.
Apple's real authorization page displayed “Magpie Sign In” for the configured
Services ID. The account owner completed authorization and Apple returned to the
registered staging callback. The backend successfully exchanged that real code,
authenticated `/me` with the resulting session, and returned `apple` from
`/me/identities`. Replaying completion returned 410. The test session was then
logged out, and using it again returned 401. The account and library were
preserved; local temporary proof/session material was removed.

Google sign-in succeeded through the Android Credential Manager and Magpie
displayed Google as connected. The APK certificate matched the registered debug
SHA-1. An emulator DNS failure was resolved by cold-starting the same AVD with
explicit DNS servers, preserving installed apps and data.

That first Google login created a separate empty staging account. A read-only
database check confirmed it contained no saved content, subscriptions, playback
positions, owned feeds/articles, newsletters, or voice records. With explicit
user approval, it was deleted through the app so Google could instead be linked
from the existing Apple account. A second read-only check confirmed that the
original Apple account and its library counts were unchanged.

The Android browser test exposed a foreground-recovery gap: staging accepted
Apple's callback, but Android had stopped polling and returning to the app did
not restart completion. The attempt expired without creating a session. Android
now resumes retained handoffs when the account screen becomes active, waits for
any existing check before retrying, and distinguishes connection failures from
other account errors. A subsequent real Apple attempt successfully signed Android
into the original account.
`make android-check` passed (42 JVM tests and lint), and the focused emulator
account suite passed all 10 tests, including foreground recovery.

On 12 September (local time), the Android app showed Apple connected. A read-only
staging database check confirmed the original account still had 49 subscriptions,
4 saved articles, and 236 playback positions. Google was then connected from that
signed-in account through Credential Manager. After signing out and signing back
in with Google, Android displayed both providers as connected. A second read-only
check confirmed both identities belonged to the same original account, no extra
account had been created, and all three content counts were unchanged. The
emulator was left signed in through Google. At that point the library was still
sample-only; the subsequent account-library work is documented in
[Android library](android-library.md).

iOS Google authorization, the remaining cross-platform acceptance scenarios,
and physical-device acceptance remain outstanding.
Production promotion is still pending those acceptance checks and authorisation.
