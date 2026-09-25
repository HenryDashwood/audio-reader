# Play App content declarations: draft answers

Draft answers for **Policy and programmes → App content** in Play Console, other
than Data safety (see [`data_safety.md`](data_safety.md)). Nothing here has been
submitted. Grounded in Android release `1.0.0` (versionCode 1, minSdk 31,
targetSdk 37) as of 25 September 2026. Items marked **Owner decision** need an
answer before submission.

## Privacy policy

`https://audio-reader-production.up.railway.app/privacy`

Source: `backend/src/audioreader/static/privacy.html` (last updated 25 September
2026). It covers iOS and Android: on-device recognition, offline Google voices,
Credential Manager, TalkBack diagnostics and the default-on Android diagnostics
switch (iOS has none), OpenAI and the other processors as service providers,
search terms in 30-day operational logs, deletion without the app, and a
**Newsletters** section (the magpieinbox.com address, Cloudflare Email Routing,
what is stored, 7-day raw-email and 30-day pending retention, block/unfollow,
"sign up for me", and deletion). It must stay consistent with
[`data_safety.md`](data_safety.md).

## App access

**All or some functionality is restricted: Yes.** The app opens to sign-in until
a session exists (`android/README.md`, first paragraph;
`android/app/src/main/java/com/henrydashwood/magpie/auth/SignInScreen.kt`).

No invite, allowlist or waitlist is involved. `login()` in
`backend/src/audioreader/auth/service.py` creates a new user for any verified
Google or Apple identity it has not seen before. The auth router only rejects
invalid or expired proofs (401) and identity-linking conflicts (409)
(`backend/src/audioreader/routers/auth.py`). Reviewers can therefore use any
Google account, and no demo credentials are needed.

Play still asks for access instructions. Enter one instruction set:

- **Name:** Sign in with any Google account
- **Username / password:** leave blank. Magpie has no username or password of
  its own. **Owner decision:** if the Console form requires credentials, create
  a dedicated reviewer Google account, keep its password out of Git, and enter
  it in the Console only.
- **Any other information:** paste the reviewer instructions below.

### Reviewer instructions (paste into "Any other information")

```text
Magpie is a podcast and article player that can be operated entirely by voice. It is designed so blind and partially sighted users can use every feature with TalkBack, and it also works with ordinary on-screen controls. The library starts empty and is filled by following shows.

Sign in: tap "Sign in with Google" on the first screen and choose any Google account. This creates a Magpie account automatically. There is no separate Magpie username, password or invite. "Sign in with Apple" is also offered and opens a browser.

Suggested path (about two minutes):
1. Sign in with Google.
2. Tap the microphone (Ask Magpie) button at the top right. Read the AI data-sharing explanation and choose Allow, then allow the microphone permission.
3. Say "subscribe to In Our Time". Magpie finds the show, follows it and confirms aloud. It then appears in Following.
4. Tap the microphone again and say "play the latest In Our Time". Playback starts, and a media notification with play/pause controls appears.
5. Tap the microphone and say "pause", then "carry on".

Speech recognition uses Android's on-device recogniser with an English (United Kingdom) model. If the device does not have that model yet, Magpie explains this and offers to download it. Everything also works without voice: Following → Add sources searches the podcast directory, and any episode can be played by tapping it.

Articles and newsletters are read aloud with an installed offline Google text-to-speech voice (Settings → Voice). To test saved articles, share a web page from Chrome to Magpie, confirm the preview, and open Saved.

Newsletters: Settings → Newsletters shows the account's private inbound address. An email sent there appears under "Waiting for your answer" at the top of Latest, with Follow and Block.

Only the recognised text of a spoken request is sent to our server, never audio, and only after the user allows AI data sharing. Settings → Privacy & Support can turn this off again. Account deletion is at Settings → Account → Delete Account.
```

**Owner decision:** step 2 assumes the Ask Magpie button label and the consent
screen order. Walk the path once on a Play internal-test build and adjust the
wording.

## Ads

**Does your app contain ads? No.** The Gradle dependencies include no ad SDK
(`android/app/build.gradle.kts`), and the policy says "No advertising, and no
advertising identifiers".

## Advertising ID

**Does your app use advertising ID? No.** The merged release manifest has no
`com.google.android.gms.permission.AD_ID`
(`android/app/build/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`).
Re-check the merged manifest after any dependency change.

## Content rating (IARC questionnaire)

- **Email:** the developer contact address.
- **Category:** "All other app types". Magpie is a player and reader rather
  than a game, social app or reference work.

Likely answers:

| Question area | Answer | Reason |
| --- | --- | --- |
| Violence, fear, sexuality, language, controlled substances, crude humour | **No** | The app itself creates none of this. |
| Gambling / simulated gambling | **No** | |
| Users can interact or exchange content with each other | **No** | Libraries, saved articles and newsletters are private to each account. There is no sharing between users, chat or public posting. |
| Shares user's current physical location with other users | **No** | |
| Allows users to purchase digital goods | **No** | No in-app purchases or billing library. |
| Unrestricted internet / web browsing | **Owner decision: likely Yes** | Capture page opens any HTTPS page in an in-app WebView, and articles link to the open web (`android/README.md`, "Incoming sharing and browser capture"). |
| Content from third parties that is not moderated | **Answer truthfully: user-chosen** | Magpie plays any podcast or RSS feed the user follows. Publishers' content is not moderated. Where the questionnaire asks, describe it as user-selected third-party media, like a podcast app or browser. |

This will probably produce a low rating (such as PEGI 3 / Everyone) with
"Unrestricted internet" or "Users interact" style descriptors, depending on the
browsing answer. Rating authorities treat general-purpose podcast players this
way.

## Target audience and content

- **Target age groups:** 18 and over. **Owner decision:** 16–17 is also
  defensible. Avoid any group under 13.
- **Could the app unintentionally appeal to children? No.** The listing and
  design are plain and accessibility-focused, with no cartoon characters,
  games or child-oriented themes.
- **Not in the Designed for Families programme.** The privacy policy says the
  app "is not directed at children under 13".

## News apps

**Is your app a news app? No** (confirmed by the owner, 25 September 2026).

Play's news declaration covers apps that publish or aggregate news they select,
for example news publishers, editorial aggregators and news magazines. Magpie
publishes nothing and selects no content: the library is empty until the user
chooses feeds, and it plays or reads only those feeds, saved links and the
user's own newsletters. That makes it a general-purpose podcast/RSS client, like
other podcast players in the **Music & Audio** category.

Category: **Music & Audio** (confirmed by the owner, 25 September 2026).
News & Magazines was rejected because it makes a "news app" classification more
likely and brings the news policy's publisher-transparency requirements. Revisit
both answers if Magpie ever ships curated or default news feeds.

## Other declarations

| Declaration | Answer |
| --- | --- |
| Government app | **No** |
| Financial features | **No** (no payments, lending, trading, banking or crypto) |
| Health apps | **No** (no health or medical features; accessibility is not a health feature) |
| COVID-19 contact tracing / status | **No** |
| Children's apps / Families | Not applicable |
| Data safety | See [`data_safety.md`](data_safety.md) |

### AI-generated content

**Owner decision:** Play's AI-generated content policy applies to apps whose
generative AI features create content, and it expects in-app reporting of
offensive output. Magpie sends voice requests to OpenAI. The model interprets
the request, calls fixed Magpie actions, and streams a short spoken reply
(`assistant_delta` events in
`android/app/src/main/java/com/henrydashwood/magpie/voice/VoiceWire.kt`). It
does not generate articles, images or media. Magpie probably falls outside or at
the edge of that policy, as an assistant that carries out tasks. If the Console
asks, answer that generative AI is used to understand requests and word short
confirmations. Decide whether to add a simple "report a problem with this reply"
action to Ask Magpie before submission. No such action exists today.

## Foreground service: media playback

The manifest declares `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MEDIA_PLAYBACK`
for `.playback.PlaybackService` (`foregroundServiceType="mediaPlayback"`,
`android/app/src/main/AndroidManifest.xml`). It is a Media3
`MediaSessionService` (`android/README.md`, "Media3 playback owned by a
`MediaSessionService`").

**Task type:** Media playback.

**Description to enter:**

> Magpie is a podcast and article player. When the user presses Play on a
> podcast episode or on an article (read aloud with an on-device text-to-speech
> voice), a Media3 MediaSessionService plays the audio as a media-playback
> foreground service. This lets listening continue with the screen off or while
> the user is in another app, and shows the standard media notification and
> lock-screen controls (play/pause, seek, skip). Pausing, stopping, the sleep
> timer expiring or closing the player ends the foreground state. The service
> never starts on its own. It runs only after an explicit play action by the
> user from the app, a home-screen shortcut, a Quick Settings tile or a media
> control.

**Impact if deferred or interrupted:** the user's audio would stop as soon as
they leave the app or lock the phone. For blind users in particular, who
listen with the screen off, the app could not be used.

**Demo video (a link Play requires; unlisted YouTube or Drive):** about 30–45
seconds on a Play internal-test build:

1. Open Magpie, signed in, with one followed show.
2. Tap an episode and Play. The mini player appears.
3. Press Home. Audio keeps playing, and the Magpie media notification is shown.
4. Pull down the shade and pause and resume from the notification.
5. Lock the screen. The lock-screen media controls work and audio continues.
6. Unlock, open Magpie, and play an article to show narration continuing in
   the background the same way.
7. Pause. The notification becomes dismissible, showing the foreground state
   has ended.

**Owner decision:** record this once a Play-signed internal build exists. Do not
show a real personal account's email in the video.

## Sensitive permissions and justifications

Only one permission is runtime-dangerous. The rest are normal or install-time.
Play has no separate declaration form for `RECORD_AUDIO`, but the Data safety
answers and this text should agree if review asks.

| Permission | Why Magpie needs it |
| --- | --- |
| `RECORD_AUDIO` | Ask Magpie voice requests. The microphone opens only after the user taps the microphone, uses a trusted home-screen shortcut, or uses the Ask Magpie Quick Settings tile, with the device unlocked and Magpie in the foreground. Recognition runs on the device through Android's on-device `SpeechRecognizer`, with no network fallback. Audio is neither uploaded nor stored (`android/app/src/main/java/com/henrydashwood/magpie/voice/AndroidSpeechInput.kt`; `android/README.md`, "Ask Magpie" and "Home screen shortcuts and Quick Settings"). A denied permission leaves every on-screen feature working and offers Open settings. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Background podcast and article playback. See above. |
| `WAKE_LOCK` | Keep playback and on-device narration running with the screen off. |
| `VIBRATE` | Non-visual cues: a strong vibration when the microphone is live and an error vibration (manifest comment; `android/README.md`, "Ask Magpie"). This is an accessibility requirement for blind users. |
| `INTERNET`, `ACCESS_NETWORK_STATE` | Account library, streaming audio, article images. `ACCESS_NETWORK_STATE` is merged from a library and used to retry queued work after connectivity returns. |
| `USE_BIOMETRIC`, `USE_FINGERPRINT` | Merged by AndroidX Credential Manager for Google sign-in. Magpie does not call biometric APIs itself. |
| `BIND_QUICK_SETTINGS_TILE`, `BIND_APP_FUNCTION_SERVICE` | Protection permissions on Magpie's own tile and AppFunctions services, not permissions Magpie requests. |

Not requested: location, contacts, storage/media, phone, SMS, notifications
(`POST_NOTIFICATIONS`), accessibility service, query-all-packages, exact alarms.
The `<queries>` entries are limited to TTS and speech-recognition services.

## Data deletion

- **In app:** Settings → Account → Delete Account, then confirm. The server
  deletes the account and its content, and Magpie clears the local session
  only after the server confirms (`android/app/src/main/java/com/henrydashwood/magpie/ui/SettingsScreen.kt`,
  `AccountActions`; `delete_user()` in `backend/src/audioreader/auth/service.py`).
  If Apple is connected, the backend also revokes the Apple authorisation.
- **Web (required by Play for apps with accounts):**
  `https://audio-reader-production.up.railway.app/delete-account`, being added
  separately. **Owner decision:** confirm it is deployed to production and works
  for a user who no longer has the app before entering it.
- **What is deleted:** account, sign-in identities, subscriptions, positions and
  progress, saved articles and captured text, newsletter address, newsletter
  issues, original emails, blocked senders and sign-up records, and
  voice-request receipts.
- **What is kept, and for how long:** pseudonymous diagnostic and
  request records and operational logs (which can contain typed search terms)
  in Logfire for up to 30 days, and database backups for up to 30 days (policy,
  "Deleting your account"; `/delete-account`, "What is kept").
- **Partial deletion without deleting the account:** users can unfollow shows,
  remove saved items, block newsletter senders, clear Latest, and turn off AI
  sharing and diagnostics.
