# Siri and Shortcuts review

Reviewed 6 September 2026. This records the original code and platform review. Implementation details and remaining device checks are in [Siri, Shortcuts, and system controls](siri-shortcuts.md).

Magpie should expose everyday listening operations as small, composable App Intents, with a separate conversational action for requests that need interpretation. Both entry points should use the same application operations as the in-app voice flow. A user should be able to finish routine requests without opening the app, and should not have to repeat a request when foreground interaction becomes necessary.

## Existing coverage and concrete gaps

The app registers five App Shortcuts: Ask Magpie, Play Latest, Play a Show's Latest, Subscribe, and Play Episode. Ask Magpie opens the microphone; the others attempt to work in the background. System media controls already support play, pause, seeking, and fixed skip intervals through `PlaybackCoordinator`.

| Finding | Evidence | Recommended change |
| --- | --- | --- |
| Playing a Siri-selected item loses its saved position. | `EpisodeEntity` reconstructs an `Episode` without `positionSeconds` or `completed`; `PlayEpisodeIntent.perform()` plays that incomplete value. Both players derive their starting position from those fields. | Treat entities as identifiers and display metadata. Resolve the full current item before playback, preserving a more recent in-memory position when appropriate. Test both podcasts and articles. |
| Finding an episode invokes an action-capable command pipeline. | `EpisodeQuery.entities(matching:)` sends `play <query>` to `/command`. System entity resolution can happen before an action is selected and may run repeatedly. | Use read-only library search and return ranked candidates. The existing `searchLibraryEpisodes` API provides a starting point. Any semantic fallback must also be read-only. |
| Siri has diverged from the newer voice pipeline. | `SubscribeIntent` and episode resolution call `/command`, whose router uses `service.interpret`; in-app voice uses `/command/stream` and `converse`. | Share execution and recovery for conversational requests. Use direct typed operations for simple controls, avoiding model calls for known actions. |
| Subscription clarification ends too early. | `SubscribeIntent` speaks `response.spokenResponse` but does not handle `expectsReply` or carry conversation turns into another request. It posts a subscription change even if nothing changed. | Request the missing value or disambiguate within Siri; preserve the conversation during any handoff. Report and refresh only confirmed changes. |
| A cold-start “continue listening” path is missing. | The current parameterless shortcut selects the newest item. Saved playback restoration is initiated by `ContentView`, rather than a dedicated background intent. | Add an explicit resume operation that restores the last item and position without requiring the library screen to appear. Define a helpful response when nothing has been played. |
| Background success can be reported before playback is established. | Play intents return “Playing” after initiating playback; later loading or article failures surface through player state and the foreground UI. | Give intent execution a bounded playback-start result and map failures to useful spoken responses. Validate audio-session handoff on a device. This is a control-flow risk, not a reproduced Siri failure. |
| Entity lookup and indexing need lifecycle handling. | Identifier resolution makes sequential network requests and suppresses individual failures with `try?`; suggestions fetch recent items. Shortcut parameter refresh is wired to subscription notifications, with no explicit equivalent at authentication/server changes. | Distinguish missing items from unavailable service. Add bounded lookup and account/server-scoped metadata caching; refresh on relevant library changes and clear stale account data on sign-out. |

Implementation references: [intents](../../ios/Hearful/Intents), [API client](../../ios/Hearful/API/HearfulAPI.swift), [playback restoration](../../ios/Hearful/Audio/PlaybackRestore.swift), [playback coordinator](../../ios/Hearful/Audio/PlaybackCoordinator.swift), [command routes](../../backend/src/audioreader/routers/commands.py).

## Delivery order

### 1. Repair the existing entry points

Fix position preservation, read-only entity resolution, clarification, and truthful completion first. Add intent/query tests: the existing player and command tests do not directly exercise these adapters. Keep the existing Ask Magpie shortcut as the immediate microphone entry point, including its cold-launch handoff.

### 2. Expose everyday listening controls

The following are proposed action names and user goals. Exact Siri phrase matching needs physical-device validation; these examples are not claims about phrases that already work.

| Action | Example goal | Execution and useful output |
| --- | --- | --- |
| Continue Listening | “Continue listening in Magpie.” | Restore and resume the last item; return the item. |
| Pause / Resume | “Pause Magpie.” | Operate on the active player; speak clearly if there is no active item. |
| Skip / Seek | “Go back two minutes in Magpie.” | Accept a typed duration and direction, or an absolute position; clamp to the item's bounds. |
| Set Playback Speed | “Set Magpie to one and a half speed.” | Accept a numeric rate; use the shared podcast/article control. |
| Set / Cancel Sleep Timer | “Stop Magpie in twenty minutes.” | Use existing timer behavior; expose the remaining timer as an output. |
| Get Listening Status | “What am I listening to in Magpie?” | Return title, position, remaining duration when known, playback rate, and timer state. |
| Mark Played / Dismiss / Undo | “Mark this as played in Magpie.” | Resolve the current or explicitly selected item; reuse existing application and undo semantics. |

Use short spoken confirmations and explicit parameters. Prefer concrete current-item context over asking the model to guess what “this” means. Extend the existing system media controls where supported so generic headset/Siri transport commands remain useful too.

### 3. Support useful Shortcuts workflows and dictated requests

Add a **Run a Magpie Request** action that accepts text supplied by Siri's parameter prompt or a previous Shortcuts action. This avoids opening Magpie merely to dictate the same request again. Route it through the newer conversation executor, retaining request identity, clarification turns, current-item context, cancellation, and recovery. If the request requires the app, hand over the captured text and conversation rather than opening an empty microphone session. Respect foreground/background execution constraints rather than assuming an arbitrarily long background task.

Expose deterministic building blocks alongside that conversational action:

- **Find Items**: search library content, with useful filters such as show, unheard status, and duration where supported. Return item entities rather than just a spoken sentence.
- **Play Item**: accept an item returned by search, preserving the distinction between podcasts and readable articles.
- **Follow Show or Publication**: accept a name or URL and return the followed source. Reuse discovery and clarify ambiguous matches.
- **Get Newsletter Address**: return text that another shortcut can copy or use.
- **Open Item / Show / Latest / Following / Now Playing**: navigate to a specific destination when the user wants the screen.

For example, a user could build “Find an unheard item from this show → choose one → play it → set speed → set a sleep timer.” Each step should return usable data and propagate failure so later steps do not report a completed routine after an earlier failure.

Add parameter summaries and descriptive entity properties. Include show/publication and article/episode distinctions in disambiguation. Apple's entity queries can also support generated Find actions in Shortcuts. [Apple: Accelerating app interactions with App Intents](https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents/).

Following a publication URL can reuse existing functionality. Importing and reading any arbitrary webpage is a separate content-ingestion feature and should not be presented as an existing operation with a shortcut added around it.

### 4. Improve entry-point discovery

Provide a small accessible Siri and Shortcuts page with a few useful phrases, a Siri tip, and a link to Magpie's actions. The existing Ask Magpie shortcut is already suitable for Action button setup; Continue Listening would be another strong option. Dedicated Control Center and Lock Screen controls would require a WidgetKit control implementation and should follow the core actions. Apple provides [SiriTipView](https://developer.apple.com/documentation/appintents/siritipview) and [ShortcutsLink](https://developer.apple.com/documentation/appintents/shortcutslink) for discovery.

After entity identity and lifecycle handling are reliable, consider indexing selected library items in Spotlight, exposing the item on screen as context, and donating successful user-initiated interactions. Avoid indexing the entire remote catalog. These features need updates and deletion handling as content and accounts change. [Apple: Explore advanced App Intents features for Siri and Apple Intelligence](https://developer.apple.com/videos/play/wwdc2026/343/).

### 5. Prototype native Siri audio discovery

The existing shortcut phrases deliberately work around media requests being routed to another app. Adding phrase variants alone will not resolve that architectural gap. The code also records a previous unsuccessful attempt to adopt `AudioPlaybackIntent`; changing that protocol back without reproducing the device behavior would not establish a fix.

Apple now documents a native audio flow using audio-schema entities, `IntentValueQuery`, `AudioSearch`, and the `audio.playAudio` schema. This is a strong direction for natural requests to find and play Magpie content. [Apple: Responding to audio search and playback requests](https://developer.apple.com/documentation/mediaintents/responding-to-audio-search-and-playback-requests).

The installed SDK marks the new MediaIntents framework as iOS 27+. Magpie still supports iOS 26, so keep the core actions available there and gate the new integration by compiler/SDK and runtime availability. Prototype podcasts first using appropriate show and episode schemas; do not label every written article as a podcast to satisfy a schema. [Apple: Audio schemas](https://developer.apple.com/documentation/appintents/app-schema-domain-audio).

Evaluate the established SiriKit `INPlayMediaIntent` route for iOS 26 only if on-device comparison shows it materially improves routing over the existing App Shortcuts. It is a distinct integration with its own handling lifecycle, not a synonym for `AudioPlaybackIntent`. [Apple: INPlayMediaIntent](https://developer.apple.com/documentation/intents/inplaymediaintent).

Replacing Siri on the iPhone side button is not a general rollout option: Apple's conversational-app side-button integration currently requires Japan eligibility and a specific entitlement. The Action button remains a separate route. [Apple: Launching your voice-based conversational app from the side button](https://developer.apple.com/documentation/appintents/launching-your-voice-based-conversational-app-from-the-side-button-of-iphone).

## Verification and latency

Use unit/integration tests for entity queries having no side effects, saved position retention, missing/deleted content, authentication and network errors, cancellation/retry behavior, clarification, and composable action outputs. Ensure no duplicate mutations occur when a conversational request is recovered. Verify podcast and article playback, including their differing readiness paths.

Run the repository's appropriate backend and iOS gates when implementing. Validate SDK-gated work on both the supported iOS 26 runtime and the newer runtime. Siri behavior itself needs a Release build on a physical phone, as documented in the [test plan](../test-plan.md).

Test with the app open, closed, and the phone locked; with AirPods; with VoiceOver; and across slow connectivity, ambiguous names, no playback history, and account changes. Confirm that spoken confirmations do not overlap the beginning of content and that foreground handoffs retain the request. Verify that “continue listening” differs predictably from “play latest.”

Measure intent invocation to entity resolution, first useful response, and actual playback separately. Direct local controls should avoid network/model work. Use cached metadata for suggestions and context while making no promise of offline media availability. Compare Siri entry with the in-app voice path rather than assuming removing one dictation step makes the entire operation fast.
