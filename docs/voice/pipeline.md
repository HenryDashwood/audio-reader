# Voice pipeline and verification

Magpie now owns a cancellable task for each voice exchange. The microphone
starts only after permissions, assets, format conversion, and the first usable
buffer. Closing the sheet cancels capture and the network consumer; an explicit
server cancellation stops subsequent tool steps. Losing a network connection
instead leaves the claimed server request running so its result can be recovered.
Already committed changes or submitted email requests cannot be recalled.

The primary recognizer combines DictationTranscriber with SpeechDetector. A
pause is measured on the audio timeline: 1.5 seconds for open requests, or
0.7 seconds for a settled, complete local control. The transcript timer remains
a fallback. Capture is capped at 45 seconds; finalization at 5 seconds; the
entire speech operation at 90 seconds. A tap while listening finishes capture.
A tap during preparation or a response cancels that exchange and starts another.

The UI distinguishes listening, finishing transcription, and processing. The
end cue sounds when nonempty captured speech enters finalization, and only
once per turn. A single short progress cue sounds after eight seconds of
backend waiting. No spoken search narration delays playback.

Both recognizers receive vocabulary from cached subscriptions, recent titles,
the visible article, current playback, and recent clarification text. The
backup waits for final transcription rather than executing a partial guess.
Failures after the ready cue never silently start another recording. Startup
cleanup, generation checks, buffer overflow detection, and cancellation keep
old attempts from contaminating a new one. No recordings are retained in
normal use. Generic preferred-recognizer failures have a one-minute cooldown;
known permanent capability failures remain disabled until relaunch.

## Commands and compatibility

Complete local phrases support numeric/word durations, such as "go back two
minutes" and "skip forward ninety seconds", and absolute speeds such as
"play at one and a half speed". They require a whole-phrase match. "Undo that"
can restore the last locally applied speed.

Streaming requests carry `request_id`, `supports_compound_actions`,
`viewed_episode_id`, and a short list of completed action summaries. Request
context survives reopening the sheet for up to ten minutes, scoped to account
and server. "Try again" or "did that work?" reuses the pending request and
recovers its outcome; it does not submit a duplicate action.
If a confirmation is interrupted before playback starts, that same receipt
remains available to recover the unapplied playback instruction.

Action tools set `continue_request` when more of the same request remains.
The response's `actions` array preserves each ordered effect. The app confirms
once and applies all effects before exposing the final playback state. Single
actions still finish without an extra model round trip. Older clients do not
advertise compound-action support and are constrained to single actions.

The model can search the entire library with `search_library`, filtering by
kind, completed status and known duration. Unknown duration is deliberately
not treated as a match for a duration limit. It receives current listening
state and visible-item context separately. `undo_last_action` restores the
last voice filing or RSS subscription change within ten minutes, provided the
underlying state has not subsequently changed. Email submissions are not
reversible. An unrelated action clears the undo slot.

Model requests reuse a connection within a conversation. Individual model
streams have a 30-second read timeout and 60-second total deadline; app tools
have 30 seconds, and the conversation has 120 seconds. Partial completion is
reported if later model/tool work fails.

## Request receipts and deployment

Apply Alembic migration `a904b718cf32` before deploying this backend. It adds
`voice_command_receipts` and `voice_undo`; no production migration is run by
local verification. Receipt keys belong to a user. Reusing an ID with a
different payload fails. A disconnect does not cancel a claimed operation.
Explicit `DELETE /command/{request_id}` cancels future work, including when the
cancellation arrives before the original request.

A database claim prevents concurrent or later retries from repeating effects.
A process crash between an external effect and saving its result can still
leave the outcome uncertain. Such a claim is never automatically re-executed;
after three minutes the app asks the user to check the library. This is not a
claim of exactly-once execution across an external email service. Receipt rows
are retained until account deletion so an old request ID cannot be replayed as
new. The client keeps short-lived context in memory, not a transcript archive.

## Verification

Run `make backend-check`, `make ios-build`, `make ios-test`, and
`make ios-test-latest`. The test suites cover cancellation followed by an
immediate new command, capture finishing, compound playback/speed, duplicate
requests, disconnects, cancellation-before-arrival, exact undo, library filters,
and task-completion grading. No live model call or newsletter submission is
required for those checks.

`uv run python -m evals` now defaults to the production conversation pipeline.
Use `--pipeline legacy` for comparisons with the older interpreter. The corpus
includes compound requests; the grader requires every requested effect rather
than accepting the final action alone. Live evals incur model costs. Network
fixtures still block actual subscriptions and publication fetches outside the
synthetic world; provider-hosted web search is live when the model selects it.

## Recorded speech benchmark

`AudioRecognitionBenchmarkTests.replayRecordings` is opt-in. Supply
`HEARFUL_AUDIO_EVAL_MANIFEST` and optionally `HEARFUL_AUDIO_EVAL_OUTPUT` to the
Xcode test runner. The manifest is a JSON array with `id`, `path`, `expected`,
and `vocabulary` for each local recording. Paths must be readable by the test
runner; on a physical device, bundle/copy the files into its test container.
The test compares DictationTranscriber and SpeechTranscriber using the same
recordings and writes word error rate and elapsed time for each result.
The benchmark does not measure live microphone startup or endpoint latency.

Use eval case IDs for recording IDs. The resulting transcripts can then be
graded against the intended task with:

```
cd backend
uv run python -m evals --pipeline conversation --audio-results /path/to/magpie-audio-eval.json
```

See `corpus.example.json` for the manifest format. Collect representative
recordings on the target phone: proper nouns, hesitant speech, distance,
background playback, speakerphone, AirPods, and route changes. Include quiet
controls and requests with numbers. Keep recordings local. Synthetic speech
alone does not establish real-user accuracy.

Measure warm and cold runs separately, and compare capture end to first audible
response using `capture_ended_seconds`, `response_seconds`, and
`first_audible_response_seconds` in voice-attempt telemetry. The last
timestamp comes from the synthesizer's speech-start callback, so it
includes voice startup time rather than just the call to request speech.
Check that the ready and end cues are audible and distinct, and judge haptic strength on a
physical iPhone. Simulator tests cannot establish those sensory properties.
Continuous spoken interruption while the app is talking remains a separate
experiment requiring echo-handling measurements; the explicit interrupt
control is implemented.
