# Reliable voice queries and follow-up answers

Implemented locally on 20 September 2026. No deployment or production provider
switch is included. Jev remains an evaluation adapter.

## What changed

A question is now an explicit `needs_clarification` outcome, with an expiring,
account-owned server record. It contains the pending action, stable choices and
any remaining steps. A short answer or a choice button resolves that record;
it does not need to reconstruct the action from the transcript.

For example: “Unsubscribe from The Rest Is” → a choice of History or Politics →
“Politics” → unsubscribe from the saved Politics ID. Exact distinguishing words,
labels and ordinals resolve without a model call. Other wording goes through a
small classifier that can only choose an offered ID, cancel, identify a new
request, or leave the question unresolved. The Jev evaluator can delegate an
uncertain paraphrase to the existing model.

Cancellation leaves the library alone. “Neither” asks for a distinguishing name
or topic while retaining the request. A new request abandons the old action.
“Yes” alone does not resolve an either/or question. Compound subscription
ambiguities are caught before either step executes, and subsequent steps resume
after the choice. Free-form discovery questions also retain their unfinished
request, but still require model interpretation of the answer.

Both iOS and Android send the pending question ID and the device timezone. They
show optional choice buttons that remain usable while listening, retain spoken answers and existing follow-up
preferences, and isolate context by account. Android retains these fields in its
unfinished-request journal. Transport commands remain local and clear a pending
question when the user moves on.

## API and execution boundaries

The additive `/command/stream` request fields are `clarification_id`,
`selected_option_id` and `timezone` (IANA identifier; UTC for older clients).
Each answer has a **new** `request_id`; retrying that answer keeps the same ID
and body. Responses retain all existing action fields and add:

- `status`: `completed`, `needs_clarification`, `not_found`, `unsupported`, or `failed`.
- `clarification`: `id`, `question`, `choices` containing `id` and `label`, and `expires_at`.

The legacy `/command` endpoint does not accept structured clarification answers;
clients use the conversation endpoint for them. Old clients can still receive
and answer spoken questions through their existing text history. Their frozen
Swift sources are unchanged.

Questions expire after ten minutes. A conditional database update claims the
record before executing an answer, preventing two devices or different request
IDs from consuming the same question. Existing command receipts recover an
answer after a lost connection without executing it again. Default new request
fields preserve old receipt fingerprints. Targets are revalidated against current
account access, subscriptions, pending senders and existence. Saved date bounds
are rechecked if an episode changes before the answer. A crash after claiming can
require recovery or a fresh request; this is not a claim of exactly-once external
network effects.

Episode choices with the same title and show include publication dates. If those
labels still cannot distinguish the options, the server requires an open question.

`play_matching_episode` enforces show, date, kind, unheard, saved-only and maximum
duration filters before limiting results. Code orders dates and calculates local
calendar boundaries, including daylight-saving transitions. A bare weekday means
the most recent occurrence, including today. Unknown dates cannot establish
latest/oldest, and unknown durations cannot satisfy a maximum. Public shows must
first be loaded before selection can use them.

Prompts explicitly distinguish episode dismissal from unsubscribing, seeking
from replaying, unavailable results from ambiguous choices, and a new publication
from existing subscriptions. The executor rejects adding “today” to a request for
“latest,” and rejects clarification alternatives outside an explicitly requested
day. A simple unsupported seek receives an explicit limitation. Question marks
no longer determine whether the microphone should reopen.

## Evaluation and validation

`backend/evals/conversations.py` runs complete exchanges in one synthetic database,
round-trips public request fields, and feeds actual questions into the next turn.
It checks the offered choices, lack of premature effects, final subscriptions,
playback/filing/speed effects, and whether another question remains. It records
provider calls, token estimates, spoken word count and command processing time.
Speech recognition, speech playback and user thinking time are outside this timing.

The final repeated run passed **54/54 conversations**: nine scenarios × three
repetitions × baseline/hybrid. Scenarios include names, ordinals, paraphrases,
yes followed by a choice, neither followed by a correction, cancellation, topic
changes, pending newsletters and compound requests. Four scenario types complete
without any model call: basic unsubscribe choices, ordinal choices, cancellation,
and choosing a waiting newsletter.

The broader 41-case regression run passed **40/41 for each provider path**. Both
remaining failures were extra questions, not incorrect actions. After adding the
date-choice safeguard, the focused weekday case passed **6/6** fresh runs. The
broad-topic follow-up case passed 3/3 with the baseline and 1/3 with the hybrid;
the other two hybrid runs unnecessarily asked which Alexander episode to play.
That remains a friction issue. These are small synthetic, familiar corpora, not
production accuracy estimates or evidence for a universal confidence threshold.

Local checks:

- Backend gate: 1,151 backend tests and 123 repository-script tests; lint, formatting and typing passed.
- Released v1.4.1 Swift client: compatibility replay passed without modifying its frozen sources.
- iOS 27.0, iPhone 17 simulator, Hearful scheme: build passed without warnings; 625 tests passed, one recording-replay test skipped.
- Android: build, 250 JVM tests and lint passed; emulator conversation, wire and journal tests passed, including the choice-button interaction.
- Database migration: additive upgrade/downgrade checked against the runtime schema and existing user data.

Physical-device speech, VoiceOver/TalkBack and iOS 26 runtime coverage were not
performed for this change.

Ignored raw artifacts are in `build/jev-evals/`: `conversations-verified.json`,
`reliability-final.json`, and `reliability-targeted.json`. Pilot files are retained
separately and are not merged into the final conversation score.

## Rollout

Apply the additive `a13d67b4e921` migration and deploy the tested backend through
the normal staging/promotion workflow before distributing updated clients.
Keep the current production model while gathering real completion and extra-question
rates. A Jev rollout remains a separate decision; the new protocol works with either
provider and does not require changing the confidence threshold.
