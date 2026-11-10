# Apple, Google, and linked accounts

Apple and Google sign-in are implemented on iOS and Android. iOS keeps its native
Apple sheet; Android opens Apple's authorization page in a browser Custom Tab.
A person signed in to Magpie can connect another provider by authenticating with
it in Settings → Sign-in Methods. Both identities then resolve to the same user
ID, library, and listening progress. If the additional identity already belongs
to another Magpie account, explicit linking combines that account into the
currently signed-in account. Linking never grants AI consent; combining existing
accounts withdraws the current choice until the person reviews the combined
library's AI sharing in Settings.

Android loads the signed-in account library and uses samples only while signed
out. Sample content and local sample bookmarks are never uploaded automatically.
Existing iOS Apple users can sign in directly with Apple on Android when the
backend's Services ID is associated with the iOS App ID.

## Provider configuration

The registrations below identify the intended project and package/certificate
pairs. Check the provider consoles and distributed build when changing them;
this guide does not establish the current OAuth audience or deployment state.

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
| Release package | `com.henrydashwood.magpie` |
| Android release Google clients | "Magpie Android (Play)" (`102154849961-rmms…`) and "Magpie Android (upload key)" (`102154849961-f1d4…`) |
| Play app-signing SHA-1 | `B9:33:0A:6F:4F:DB:1B:05:A9:8F:22:22:9C:DC:2C:A1:45:E4:F7:BD` (Google-generated key, verified from a Play install) |
| Upload key SHA-1 | `CE:90:4F:A8:8F:31:06:AB:98:54:6C:FD:4E:E4:61:3A:BA:68:7B:40` |

Apple's saved website configuration includes both Railway domains and these
exact return URLs:

- `https://audio-reader-staging.up.railway.app/auth/apple/browser/callback`
- `https://audio-reader-production.up.railway.app/auth/apple/browser/callback`

Each backend environment needs its own callback and token encryption key, plus
the shared Services ID and Google server client ID. Staging must disable Apple
revocation on account deletion; production retains revocation. See
[backend environments](backend-releases.md#environments).

Google consent uses `openid`, email and profile. Mobile apps contain only public
client IDs. The OAuth audience and allowed testers must match the intended
release audience; a successful test-user login does not establish public access.
Register each developer's debug certificate separately. Release registration
must match the actual installed certificate, including Play App Signing.
Read it with `adb shell pm path com.henrydashwood.magpie`, pull `base.apk`, then
`apksigner verify --print-certs`. A wrong SHA-1 can surface as the account chooser
closing with "[16] Cancelled by user" in logcat.

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

When provisioning or recovering staging, deploy the revocation guard and set
`AUDIOREADER_APPLE_REVOKE_ON_ACCOUNT_DELETION=false` before adding Apple's signing
credentials. Use a separate Fernet encryption key. Verify real provider/linking
flows on disposable staging accounts before authorised production promotion.
Do not roll staging back to code without the guard while its Apple key remains
configured; deleting a staging account must not revoke production authorization.

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
Explicit properties (including empty values) override the debug defaults. Release
builds default to production and the shared web/server client ID, but require
private signing inputs and a matching declared certificate fingerprint before
building. Verify OAuth registration with the distributed build. See [Android release preparation](mobile-releases.md#android)
for the signing properties and the distinction between local/upload and Play
app-signing certificates.

Deploy through the existing staging and manual production promotion process in
[backend releases](backend-releases.md), after configuring the chosen environment.
Do not send test sign-in attempts to production as part of local verification.

### Google sign-in button assets

The iOS `GoogleAuthenticationButton` follows the light theme in Google's
[branding guidelines](https://developers.google.com/identity/branding-guidelines).
It uses a white fill, #747775 border, #1F1F1F text, Google Sans Medium, and a
20-point full-color mark. The minimum height matches the Apple button at 56
points; the native text and button height can grow with Dynamic Type.

The mark comes from Google's [official asset bundle](https://developers.google.com/static/identity/images/signin-assets.zip),
downloaded on 2026-09-15. Each `GoogleSignInMark` PNG is the central 20 × 20-point
logo from the iOS light square icon button at its original 1x, 2x, or 3x scale.
Only the surrounding button padding and border were cropped away; the logo's
pixels, colors, and proportions are unchanged.

`Resources/Fonts/GoogleSans-Medium.ttf` is the unmodified static Medium face from
[Google Fonts](https://fonts.google.com/specimen/Google+Sans), downloaded on
2026-09-15. Its SIL Open Font License is bundled as `GoogleSans-OFL.txt`.

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

A link to the same Magpie account is idempotent. Signing in separately with two
previously unlinked identities still creates two accounts, even if the email
matches. Explicitly connecting the other provider combines them after verifying
both the current Magpie session and the additional provider proof. Invalid
provider proof returns 400; an expired/revoked Magpie session returns 401.

Combination runs in one transaction, locking both users in ID order and
rechecking the initiating session after provider verification. The current
account retains its ID and sessions. Every provider identity from the other
account moves to it; the other account's sessions and pending browser handoffs
are retired, requiring those devices to sign in again. A concurrent identity
change returns a retryable 409 rather than combining an account whose user row
was not locked. Lost-response retries are idempotent.

Subscriptions are united by feed ID. Duplicate subscriptions retain the current
account's grouping and the furthest Latest cursor, so cleared items do not refill
Latest. Imported groups are flattened through existing roots. Saved items are
united by episode ID with their earliest save date. The current readable capture
wins a duplicate; a prepared incoming capture repairs an empty current one.
All private immutable text versions survive. The most recently updated playback
record wins only when it matches the selected content version, preserving its
completion/dismissal flags. Seconds from different text versions are never mixed.

Private newsletter feeds, messages, and signup records move with their owner.
Migration `e94d82c617ab` adds newsletter inbox aliases: both old addresses keep
delivering to their original feed namespaces, including independent sender
approval/block choices. Deleting the combined account removes these aliases.
Undo records describing either old library are invalidated; command receipts for
the current account remain so retries cannot repeat actions. AI consent must be
reviewed again after a combination. iOS refreshes its account, Following, Latest,
Saved, and shortcut data; Android refreshes its library after a successful link.
The existing provider-list response contract remains unchanged. Older clients
can link through the same endpoint, then refresh their library.

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
6. Cancel each provider sheet. Check that account state is unchanged. Sign in
   separately with Apple and Google to create two test accounts, add distinct and
   overlapping subscriptions/saved items, then connect them in either direction.
   Check that both sign-ins reach the combined library, the current session stays
   signed in, and the other account's old sessions require sign-in. Verify both
   newsletter addresses still deliver, text versions keep matching progress, and
   AI sharing asks for consent again. A failed provider proof must change neither
   account.
7. Reopen both apps, test offline restoration and server-revoked sessions, then
   delete a disposable linked account and verify both methods lose access to it.
8. Check VoiceOver, TalkBack, large text, dark mode, and device account selection
   on physical devices. Simulator and mock tests cannot validate provider setup.
