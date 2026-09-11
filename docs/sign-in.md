# Apple, Google, and linked accounts

Apple and Google sign-in are implemented on iOS and Android. iOS keeps its native
Apple sheet; Android opens Apple's authorization page in a browser Custom Tab.
A person signed in to Magpie can connect another provider by authenticating with
it in Settings → Sign-in Methods. Both identities then resolve to the same user
ID, library, listening progress, and consent choice. Linking does not grant AI
consent or copy/move any library data.

Android still uses a sample library. Its account screen clearly states this and
never uploads sample content or local article bookmarks. Android's Apple browser
flow is implemented; account-backed library loading remains unfinished in parity
item 1. Existing iOS Apple users can sign in directly with Apple on Android once
the configured backend has been deployed and the acceptance checks below pass.

## Provider configuration

Provider registrations and public Railway settings were configured on 11 September
2026. No backend was redeployed. The new endpoints and migration still need the
normal staging release and subsequent manual production promotion. Existing
native Apple sign-in works independently of the browser configuration.

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
existing Apple key and encryption settings were preserved. Staging's Apple key
settings are still blank; follow the staged rollout below before adding them.

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

Staging rollout order:

1. Deploy this backend through normal CI, including the migration and
   `apple_revoke_on_account_deletion` guard. The staging Railway setting
   `AUDIOREADER_APPLE_REVOKE_ON_ACCOUNT_DELETION=false` is already saved.
2. Verify that the deployed revision includes the guard before giving staging
   the Apple team ID, key ID, and private key needed for code exchange. Use a
   separate newly generated Fernet encryption key for staging. Keep all secrets
   out of source control and logs.
3. Redeploy staging with those secrets and perform real provider/linking checks.
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
from the browser only opens Sign-in Methods; it cannot supply credentials.
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
   Check the same account ID and provider list; its sample library must remain
   explicitly separate. Verify the Services ID grouping with a real existing
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

Provider authorization itself was not exercised against real Apple/Google
accounts. Backend rollout, configured staging checks, Google production audience
publication, Android release registration, and physical-device accessibility
acceptance remain required before releasing these sign-in flows.

The final Android account screen was opened through the real browser return link
and inspected visually on the emulator. Both provider buttons, setup messages,
existing-Apple-account instructions, and sample-library disclosure were visible
without clipping at the emulator's current text size. The original unconfigured preview kept both
buttons disabled. Debug builds now contain the registered development settings;
backend rollout remains required before sign-in can complete.
