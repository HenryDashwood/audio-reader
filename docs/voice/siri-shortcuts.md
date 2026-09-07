# Siri, Shortcuts, and system controls

Magpie exposes listening and library actions in Shortcuts, plus ten suggested App Shortcuts with spoken phrases. Settings → Siri and Shortcuts explains the entry points and links to the action library. The article and Now Playing screens associate the current item with a foreground `NSUserActivity` so Siri can identify visible content. This uses `NSUserActivity.appEntityIdentifier`, which is supported by the Xcode 26 SDK, rather than the newer SwiftUI modifier. The activities do not advertise Handoff.

## Available actions

| Action | Input | Output / behavior |
| --- | --- | --- |
| Ask Magpie | None | Opens the voice sheet. VoiceOver users activate its microphone control after the sheet is announced. |
| Continue Listening | None | Resumes the loaded or remembered item, preserving progress; returns the item. |
| Play the Latest Item | None | Plays the first playable item from Latest; returns the item. |
| Play the Latest from a Show | Show | Plays its newest playable item; returns the item. |
| Play a Listening Item | Item | Resolves current server metadata, or keeps the already-loaded player's position; returns the item. |
| Pause Listening | None | Pauses the current item. |
| Skip in Listening Item | Direction and duration | Moves relative to the current position; returns the resulting position in seconds. |
| Go to Listening Position | Duration | Seeks to an absolute position; returns the resulting position in seconds. |
| Set Playback Speed | Number, 0.5–3 | Changes the active podcast/article speed; returns the applied rate. |
| Set Sleep Timer | Duration, 1 minute–24 hours | Rounds up to a whole minute; returns the timer's end date. |
| Cancel Sleep Timer | None | Cancels the timer. |
| Get Listening Status | None | Returns an entity with item, playing state, position, remaining content duration, speed, and timer end. |
| Find Listening Items | Search, optional show, unheard filter, maximum duration, result limit | Returns item entities. Empty search and show select Latest. Unknown durations are excluded when filtering by duration. |
| File a Listening Item | Filing action, optional item | Marks played/read, dismisses, or restores. Empty item means the currently loaded item; returns the updated item. |
| Undo Last Magpie Action | None | Undoes the most recent supported speed or server library change; reports conflicts instead of overwriting later changes. |
| Follow a Show or Publication | Name | Uses the conversational pipeline and asks follow-up questions as needed; returns a response summary. |
| Follow a Publication URL | Web URL | Discovers feeds, asks the user to choose if necessary, then follows the chosen feed; returns the show. |
| Get Newsletter Address | None | Returns the user's newsletter address as text. |
| Run a Magpie Request | Text | Accepts dictated or upstream Shortcuts text; returns a summary, optional listening item, and whether processing continued in the app. |
| Open Magpie Destination | Destination | Opens Latest, Following, Now Playing, or Siri and Shortcuts help. |
| Open Listening Item | Item | Opens the item's reader/details. |
| Open Show or Publication | Show | Opens its library page. |

The read-only entity queries never call the command interpreter. Explicit failures propagate as errors, so a shortcut can stop rather than continue after a failed search, playback, or library change. Suggestions use a five-minute cache scoped to both session and server. Changing account or server clears cached suggestions, pending navigation/conversation state, and playback.

A duration in Shortcuts is a real measurement: minutes and hours are converted before invoking the shared player. Remaining content duration is not divided by playback speed and article duration remains an estimate.

## Dictation and handoff

`Run a Magpie Request` accepts text directly; it does not start another transcription pass. Simple transport and sleep commands execute locally. Other requests use the same `CommandExecution` streaming adapter and `VoiceSessionContext` receipts as microphone input. Clarification keeps the preceding exchange attached.

If AI consent is needed, the app opens to the existing consent flow with the captured request retained. A request taking longer than the background budget continues in the app using its original receipt. The result's `Continued in app` property makes this explicit to a calling shortcut. Cancelling the foreground continuation does not leave a fresh request waiting to execute on a later launch.

Typed filing and undo use authenticated `POST /actions`, without an AI provider or AI consent requirement. Each action has a request identifier, a durable server receipt, and the existing conflict-aware undo mechanism. A connection failure retains the client receipt for a retry of that action. This endpoint must be deployed alongside the client; older servers cannot execute these new typed actions.

## System controls and signing

The `HearfulControls` WidgetKit extension provides Ask Magpie and Continue Listening controls for Control Center, the Lock Screen, and the Action button. Both open the app to execute; the extension itself contains no credentials, player, or library cache. The matching intent implementations are compiled into both targets so the system routes execution to the app process.

The existing app identifier and signing settings are preserved. The new extension identifier is `com.henrydashwood.hearful.controls`.

Before a distribution build, configure an App Store distribution provisioning profile for that extension using the same distribution certificate/team as the app. Store its base64-encoded profile in the GitHub Actions secret `APPLE_CONTROLS_PROVISIONING_PROFILE`. The release workflow installs it, passes `HEARFUL_CONTROLS_PROFILE_UUID` to the archive, and includes it in the export mapping. No profile or credential is created by these source changes. A missing secret produces an explicit release-workflow error.

## Optional iOS 27 audio prototype

`NativeSiriAudio.swift` contains an opt-in MediaIntents prototype. Build with Xcode 27 and `HEARFUL_SIRI_AUDIO_FLAGS=HEARFUL_NATIVE_SIRI_AUDIO` to include it. Both SDK import and runtime availability are guarded; ordinary builds retain the established iOS 26 shortcut routing.

Keep standard builds compatible with the Xcode 26 SDK used by CI. Testing on an iOS 26 simulator with Xcode 27 checks runtime behavior, but does not verify that the source compiles with the older SDK.

The prototype supplies podcast show/episode schemas, structured read-only audio search, and the native play schema. It supports known library URLs and unspecified requests that can resume or choose a recent podcast. It does not pretend articles are podcasts or implement a playback queue. Unsupported queue, shuffle, repeat, and warmup requests fail explicitly. The prototype compiles and passes App Intents metadata extraction; enabling it for releases still requires physical-device Siri testing on the final OS.

Content-wide Spotlight indexing, interaction donation, a legacy SiriKit extension, Watch, CarPlay, and arbitrary webpage ingestion are not enabled by this change. They remain separate follow-ups; the current work supplies stable entities and shared operations that those integrations can reuse.

## Physical-device acceptance

Use a Release build on a phone; do not uninstall an existing physical-device install. Simulator speech recognition is not representative of Siri.

- Confirm Magpie's actions appear in Shortcuts. Exercise a saved multi-step shortcut: find → choose → play → set speed → set timer.
- Say “Continue listening in Magpie” with the app closed, open, and the phone locked. Verify saved positions for both podcasts and articles.
- Try AirPods and VoiceOver. Check that Siri confirmations and content start do not obscure each other.
- Search ambiguous show/item names and answer clarification. Try names that are not among recent suggested items.
- Run a dictated request, a slow request requiring foreground recovery, and a request requiring AI consent. Confirm there is no second dictation or duplicate library mutation.
- Cancel a foreground handoff, then open Magpie later: the cancelled request must not start.
- File an item, undo it, and verify its earlier position and flags. Change it elsewhere before undoing and check the conflict response.
- Change speed through in-app voice, then undo through Siri; repeat in the other direction.
- Test no playback history, removed content, offline operation, expired sign-in, and account/server changes.
- Add each Magpie control to Control Center and the Lock Screen. Confirm both reach the app process and perform the advertised action.
- Compare native “play … in Magpie” routing with and without the opt-in iOS 27 prototype before enabling it in a release.
