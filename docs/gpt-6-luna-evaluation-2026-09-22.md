# GPT-6 Luna voice-command evaluation — 2026-09-22

Final decision: use `gpt-6-luna` with reasoning `none` as the repository default
after the context and evaluation fixes. Both models passed 43/43 commands and
9/9 clarification scenarios. See [the corrected comparison](#results-after-the-fixes).
This is a local code change; no deployment was performed.

Initial decision (before the context/fixture fixes below): retain direct OpenAI `gpt-5.6-luna`, reasoning `none`. GPT-6 Luna
supports the existing API, but the live synthetic evaluation found reliability
regressions. No production deployment or client change was made. The candidate
model and prompt edits were reverted; GPT-6 Luna's prices remain available in
the evaluation cost estimator.

## Compatibility and price

[OpenAI's GPT-6 Luna model page](https://developers.openai.com/api/docs/models/gpt-6-luna)
documents Responses streaming, function calling, structured outputs, web search,
and reasoning `none`. It does not support audio input/output. In Magpie this
model interprets text transcribed on the phone; it does not replace speech
recognition or the reading voice.

Standard USD per million tokens, checked 2026-09-22:

| Model | Input | Cached input | Cache writes | Output |
| --- | ---: | ---: | ---: | ---: |
| GPT-5.6 Luna | 0.20 | 0.02 | 0.25 | 1.20 |
| GPT-6 Luna | 0.10 | 0.01 | 0.125 | 0.50 |

GPT-6 Luna's input rates are 50% lower and its output rate is about 58% lower.
Actual cost also depends on tool calls, tokens, and caching. These rates do not
establish better command accuracy.

## Completed comparison

**Follow-up audit:** these are raw grader outcomes, not a clean comparison of
real-world accuracy. The context/fixture audit below qualifies the restore and
weekday results and the meaning of `asked`.

One pass through the 41-case corpus per model, with the experimental show-filter
instruction below applied identically to both:

| Model | Completed | Asked | Failed | Provider errors | Median command time | Estimated token cost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| GPT-5.6 Luna | 40 | 1 | 0 | 0 | 2.04 s | $0.05148 |
| GPT-6 Luna | 38 | 2 | 1 | 0 | 1.65 s | $0.02445 |

Both models left the weekday request unresolved. Only GPT-6 Luna left the
restore request unresolved and asked an unnecessary choice for the clear
latest-item request. An `asked` result is safe but is not a completed request;
the grader marks clarification as `fail` where the case explicitly requires
acting without another question.

GPT-6 Luna completed all nine separate multi-turn clarification scenarios in
one pass using the restored original prompt. These cover ordinals, semantic
replies, a vague yes, neither/correction, cancellation, subject changes,
newsletter names, and remaining compound steps.

Command times exclude artificial API pacing and fixture setup; they include
retrieval, model calls, and execution, not phone speech or playback latency.
Token costs exclude web-search fees; each full corpus made one hosted search.
Synthetic cache reuse limits how well these costs predict live traffic.

Final local validation: `make backend-check` passed dependency sync, Ruff lint
and formatting, ty, 1,152 backend tests, and 123 repository-script tests.

## Observed regression and attempted prompt correction

With the original prompt, GPT-6 Luna twice subscribed to The Infinite Monkey
Cage and then played an episode from a different show. Its subsequent
`play_matching_episode` call used `feed_id: null`, searching the whole library.
The initial paced run was stopped after 50 results: 47 pass, 1 asked, 2 fail.
GPT-5.6 Luna passed the affected request three out of three times with the
original prompt.

An experimental prompt addition made the existing tool semantics explicit:

```text
When the user names a show, preserve that show in play_matching_episode's feed_id;
null searches the whole library. If the feed ID is not supplied, call load_show_episodes
with the verified feed URL and use its returned feed_id. This also applies after
subscribe_to_feed: subscribing does not implicitly scope later playback to that show.
```

GPT-6 Luna then passed the affected request three out of three times. Both
models were also evaluated against the full corpus with this same experimental
prompt. GPT-6 Luna still asked for a choice instead of playing the latest item,
and declined a restore request that GPT-5.6 Luna completed. The prompt addition
was therefore not retained as part of a model upgrade.

## Reproduction and limits

Only synthetic libraries and utterances were sent. App-side feed/directory
requests and mutations were mocked. Hosted web search could still run.
The comparison used reasoning `none`, the existing conversation executor,
60 recent plus 15 matching older candidates, a 2026-09-22 reference date,
seed 42, and a four-second minimum interval between model calls.

The first unpaced parallel attempts exceeded the account's 200,000 tokens per
minute limit. Their errors are not accuracy results. Subsequent complete
corpus runs were paced; clarification conversations ran after the candidate
corpus. Logfire emitted its expected not-configured warning in the standalone
evaluation processes.

Example candidate run (the retained repository uses the original prompt):

```sh
cd backend
AUDIOREADER_OPENAI_MODEL=gpt-6-luna uv run python -m evals.compare_jev \
  --modes baseline --repeat 1 --openai-interval 4 \
  --json ../build/gpt6-luna-evals/candidate.json
```

The original runs used the environment override because `evals --model` did
not set the direct Responses model. That CLI bug is now fixed. Raw outputs for this investigation
are in ignored `build/gpt6-luna-evals/`, including `before-prompt-corpus.json`,
`fixed-play-unsubscribed.json`, `final-corpus.json`,
`previous-model-corpus.json`, and `final-conversations.json`.

This is a small regression corpus, not a held-out accuracy benchmark. The
prompt correction was tuned on a failure in this corpus. Phone transcription,
speech output, playback startup, and real-device latency were not measured.

## Follow-up context and fixture audit

- The active conversation prompt omits the legacy interpreter's explicit rule
  that “the latest” without a show means the newest item across subscriptions.
  It also omits the legacy rule that playing a public show does not require
  subscribing. The model should be given these product defaults explicitly.
- `subscribe_to_feed` returns title/status but no `feed_id`. The original
  subscription list is not refreshed within the tool loop. Subsequent playback
  therefore requires another lookup to obtain the ID; returning the verified
  ID in the tool result would eliminate this information gap.
- Initial candidates expose publication dates without times. Their listening
  state is supplied in a separate list joined by episode ID. A single record
  per episode with feed ID, full timestamp, and state would remove avoidable
  cross-referencing. Ordering should remain code-owned.
- `restore-this` never seeds a dismissed/completed position. The context tells
  the model both flags are false. `restore` is implemented as an idempotent
  setting of those flags to false, but its brief tool description does not
  explain that behavior. The model's refusal is a mismatch with this tool
  contract, not evidence that it cannot restore an actually dismissed item.
  Test actual dismissed/completed states and already-restored behavior separately.
- On Tuesday 2026-09-22, the synthetic feed generator excludes the reference
  day and supplies its newest Politics episode on 2026-09-15. The application
  interprets “Tuesday” as 2026-09-22, including today as documented. GPT-5.6's
  not-found result is consistent with the supplied data. Pin the fixture clock
  and align the expected result with the intended weekday policy.
- The single-request grader categorizes any unexpected `Action.UNKNOWN` as
  `asked` when questions are allowed. This includes unsupported refusals and
  not-found results. The two GPT-6 `asked` results are not both clarification
  questions. Score statuses and resulting state separately.
- Playback grading checks the chosen episode but does not reject an additional
  subscription. GPT-6 subscribed in the observed public-show playback case,
  whereas GPT-5.6 loaded and played the show without subscribing. Future
  evaluations should assert that unrequested side effects did not occur.

These findings weaken the earlier broad inference that the score difference
alone demonstrates inferior model reliability. The wrong-show execution is
still a real observed failure. Repair the context/tool contracts and fixtures,
then compare both models again before deciding on the upgrade.

## Implemented fixes

- The conversation instructions now state the product's defaults for latest
  across subscriptions, named shows, public playback without subscribing,
  and unqualified weekdays. A contradictory compound example was corrected:
  “play it at one and a half times speed” changes speed only; a request naming
  an episode/show and a speed carries out both actions.
- Both new and already-existing subscription results expose the verified
  `feed_id` and canonical feed URL. The executor rejects a null playback filter
  after a show lookup/subscription has resolved a feed, except for explicitly
  library-wide wording. This constraint lasts only for the current request.
- Initial and retrieved episodes use the same complete JSON record: episode
  and feed IDs, title, description, full UTC publication timestamp, kind,
  duration, completion, dismissal, and playback position. Filing tool results
  return refreshed episode state. The evaluation-only Jev adapter understands
  the new records as well as the older recorded format.
- Restore's tool description documents the actual existing behavior: clear
  both flags and reset playback/reading progress to the beginning, including
  when repeated. The implementation itself has not changed.
- The synthetic world and calendar executor now share a fixed reference day
  at 23:59 UTC. That day's publications are included. Latest-overall expected
  results are derived from the selected world, including date overrides.
  Restore fixtures separately cover dismissed, completed, and already-restored
  episodes with nonzero progress.
- The grader uses response status to distinguish questions from refusals and
  not-found outcomes. It verifies persisted filing/progress and rejects
  unrequested subscriptions and extra actions, even when the final action was
  correct. Synthetic OpenAI traces now preserve the exact inputs, instructions,
  tools, and prompt/tool hashes for auditing.

The stricter grader exposed the speed prompt contradiction during an interim
run (`corrected-gpt6.json`). Both interim comparisons were stopped and are
marked incomplete; they are not combined with the final `validated-*` runs.

Regression tests cover the public-show tool chain, direct subscription-to-play
handoff, already-subscribed handoff, request-local scope, explicit library-wide
selection, complete context and updated state, all three restore starting
states, false-positive grading, weekday capitalization, and all seven reference
weekdays for latest and calendar selection.

## Results after the fixes

Both models received identical instructions and tool schemas, verified by the
saved hashes. Each ran the corrected 43-case corpus once, and then all nine
multi-turn clarification scenarios once. Model reasoning remained `none`.

| Model | Commands | Clarification scenarios | Median command time | p95 command time | Corpus token estimate |
| --- | ---: | ---: | ---: | ---: | ---: |
| GPT-5.6 Luna | 43/43 | 9/9 | 1.49 s | 5.73 s | $0.08092 |
| GPT-6 Luna | 43/43 | 9/9 | 1.64 s | 6.96 s | $0.04089 |

Neither model had provider errors, unresolved questions, or disallowed side
effects in the complete final corpus. GPT-6 Luna's estimated token cost was
about 49% lower, with slightly higher latency in this run. Both corpora used
one hosted web search; search fees are excluded. Timings exclude the explicit
six-second benchmark pacing. These synthetic results do not prove general
superiority, statistically establish latency differences, or measure phone
speech quality. The prompts were tuned using this regression corpus.

Raw evidence is in `build/gpt6-luna-evals/validated-gpt6.json`,
`validated-gpt56.json`, `validated-gpt6-conversations.json`, and
`validated-gpt56-conversations.json`. The command traces include the exact
request context for every API call. Earlier and interrupted runs are retained
separately and are not included in these results.

The optional OpenRouter provider retains its earlier evaluated model. No
client API shape changed; the frozen v1.4.1 Swift client compatibility check
passed. Production environment overrides may pin an older model independently
of the new repository default.

Final verification with GPT-6 Luna selected: `make backend-check` passed
dependency sync, lint, formatting, typing, 1,186 backend tests, and 123 script
tests. A constructed conversation request resolves to `gpt-6-luna`, reasoning
`none`, and `store: false`. The full final gate emitted no warnings. No phone
test, production deployment, or environment override change was performed.
