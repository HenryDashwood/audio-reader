# Android parity acceptance

Updated 17 September 2026. The implementation checklist is in
[android-parity.md](android-parity.md). A checked feature is not proof of release
acceptance on every device. The owner has no phones/headphones available and no
Google Play app yet; use the emulator for the checks possible now.

## Automated and emulator coverage

- Account isolation, linked-provider contracts, durable library/capture/request
  recovery, podcast progress and shared UTF-16 article bookmarks have automated
  coverage. Earlier staging acceptance verified Apple and Google on one account.
- Media3 service tests cover paused restoration, fresh remote podcast position,
  silent article restoration, explicit system Play, service recreation, dismissal,
  completion, a new listening choice, account changes and cancellation by Pause.
  Recreating the service is not a physical process-kill or Bluetooth test.
- The installed offline emulator voice completes replies at both a faster and a
  slower article speed. This establishes completion, not phone voice quality.
- The suite exercises platform AppFunctions, trusted/untrusted callers, media
  browsing, launcher actions, Quick Settings, structured and conversational actions.
  It does not establish Gemini discoverability or natural-language routing.
- WebView fixtures exercise Readability capture, navigation/origin guards and
  confirmation. They do not establish compatibility with every publisher login.
- Existing large-text/dark-mode screenshots and automated accessibility semantics
  supplement, but do not replace, a TalkBack session on a phone.

## Open acceptance matrix

| Check | Procedure and pass condition | Dependency |
| --- | --- | --- |
| Phone playback | Stream a real podcast; lock/unlock, background, interrupt with a call, unplug headphones and reconnect Bluetooth. Position is preserved; audio never resumes unexpectedly. | Android phone, headphones |
| Restart/system resumption | Pause a podcast and article, allow ordinary process death (not force-stop), then use system Play and a headset button. Resume the same account/item/bookmark. Dismissed/completed items stay dismissed. Also check reboot metadata and OEM battery restrictions. | Android phone; Pixel then Samsung coverage |
| Offline speech | Install an offline voice and recognition model, enable airplane mode, narrate a long article, speak a command, interrupt replies and change article speed. No network voice fallback; errors explain unavailable models. | Android phone with voice models |
| Accessibility | Navigate all core flows with TalkBack and large text: sign-in, capture, filing, player, voice, newsletter and recovery. Check focus, announcements, contrast, touch targets and no essential gesture-only actions. | Android phone and TalkBack |
| Cross-platform account | Sign in with Apple, link Google, then sign in using either provider on iOS and Android. Verify the same library. Separate pre-existing accounts must produce a conflict rather than merge. | iPhone, Android phone, staging accounts |
| Cross-platform progress | Alternate podcast and article playback between clients, including emoji/non-BMP text, offline progress, completion, unread and Undo. Verify matching text bookmarks and no stale clock overwrites. | Both clients against the same verified staging backend |
| Publisher capture | Share real public and signed-in publisher pages from Chrome/another browser. Sign in inside Magpie if needed, navigate redirects, capture, inspect the preview, cancel/confirm and retry offline. Capture only the intended visible article; retain no credentials in submitted HTML. | Selected publishers and user-owned logins |
| Real assistant | Ask the installed assistant to browse, continue listening, play a publication, file/Undo and open the newsletter address. Check consent, cancellation, account changes and no unintended microphone/audio. | Eligible Google Gemini/AppFunctions preview access |
| Signed distribution | Install the Play internal-test build and repeat Apple/Google sign-in/linking, browser return, offline startup and system playback. | Play Console app, signing certificates and OAuth registration |
| Diagnostics/performance | Exercise a controlled crash/freeze in a test build, check private retry/opt-out behavior and startup/long-article responsiveness under real phone memory/battery constraints. | Android test phone |

Google currently documents full Gemini AppFunctions integration as a private
preview for selected participants. EAP signup alone does not grant integration
access: [official AppFunctions documentation](https://developer.android.com/ai/appfunctions).
Do not mark real-assistant acceptance complete from instrumentation success.

Record device/OS, app commit, backend deployment, steps and outcome for each open
row. Never clear an existing account's data or delete it just to run acceptance;
use disposable staging accounts for destructive flows. Release preparation and
production promotion are tracked in [android-release.md](android-release.md).
