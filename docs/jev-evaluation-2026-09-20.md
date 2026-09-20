# Jev voice-command evaluation — 20 September 2026

The first live comparison does **not** support replacing the current conversation
model with this Jev adapter, or deploying its fallback policy as written. Jev
handled a useful subset faster, but the combined pipeline had the same regression
score, longer overall waits and higher cost under the observed cache conditions.
A less conservative confidence threshold is worth testing on new examples.

No production provider, app behaviour, credentials or services were changed.
The implementation lives exclusively in the development evaluation harness.

## Live comparison

41 existing regression cases, three repetitions, three configurations: **369
completed evaluations**, with zero provider errors in the final paced run. Baseline:
`gpt-5.6-luna`, reasoning `none`. Jev: pinned `jev-1.13.0`. The hybrid used Jev first,
then the unchanged conversation model for unsupported, missing or uncertain
decisions. The initial minimum confidence was **0.9** for every required Choice.

| Configuration | Passed | Asked instead | Failed | Median command time | p95 command time | Estimated cost per 1,000 requests |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current model | 113/123 | 0 | 10 | 1.50 s | 4.98 s | $0.60 |
| Jev only | 71/123 | 15 | 37 | 0.81 s | 0.97 s | $0.45 |
| Jev + current-model fallback | 113/123 | 0 | 10 | 1.84 s | 6.34 s | $0.92 |

The Jev-only failures mostly represent requests the bounded adapter declines,
including discovery and compound actions, or unnecessary/generic clarification.
They are **not 37 wrong executed actions**. Its 71 passes include 17 cases where
clarification was itself the expected outcome. Faster non-completions should not
be interpreted as equivalent successful work.

In the hybrid, Jev executed **58/123 requests (47.2%) directly**, spanning 20 unique
case IDs; all 58 passed. The other 65 requests fell back. Those accepted requests
had a median of **0.84 s**, versus **1.39 s** for their matching baseline
case/repetition pairs. The fallback requests had a median of **2.88 s**.

Good direct results included named topics and guests, older episodes such as
Æthelstan, the misheard “in our stand”, named-show latest episodes, simple speeds,
and marking the currently playing item finished. High confidence did not mean
broad coverage: follow-ups, filing variants and pending newsletters often fell
below the initial gate.

## Cost interpretation

The observed baseline input cache-hit rate was **98.7%**. Repeated synthetic
prompts, including an earlier exploratory run, warmed that cache. This is not a
measurement of Magpie's production cache-hit rate.

| Configuration | Token cost for 123 requests | Hosted web-search fees | Total for 123 requests | Hypothetical total per 1,000 with no input-cache hits |
| --- | ---: | ---: | ---: | ---: |
| Current model | $0.04355 | $0.03000 | $0.07355 | $3.03 |
| Jev only | $0.05492 | $0 | $0.05492 | $0.45 |
| Jev + fallback | $0.08338 | $0.03000 | $0.11338 | $2.47 |

With this unusually warm cache, the hybrid cost about **54% more** than the
baseline. Holding the same requests, outputs and tool calls fixed but charging
ordinary uncached input rates, it would cost about **18% less**. That second column
is a pricing scenario, not another live run or a prediction of uncached latency.

Prices checked on 20 September 2026: [TypeSafe](https://docs.typesafe.ai/models)
charges $0.042 per million input tokens and no output fee.
[OpenAI standard pricing](https://developers.openai.com/api/docs/pricing) for Luna
is $0.20 input, $0.02 cached input, $0.25 cache writes, and $1.20 output per million
tokens, plus $0.01 per hosted web-search call. Estimates use returned usage,
including cache writes. They are not billing statements. The live comparison cost
about **$0.24** across the three configurations; smoke and discarded exploratory
runs are additional.

## Confidence sensitivity: offline replay

The same 123 Jev-only responses were replayed through the real action executor
and grader at six thresholds. This used no additional API calls. The 0.9 replay
reproduced the original grades and proposed tool calls exactly.

| Minimum confidence | Direct actions accepted | Wrong/incomplete accepted actions |
| --- | ---: | ---: |
| No gate (0.0) | 87/123 | 3 |
| 0.5 | 82/123 | 0 |
| 0.7 | 72/123 | 0 |
| 0.8 | 65/123 | 0 |
| 0.9 | 54/123 | 0 |
| 0.95 | 46/123 | 0 |

Without a gate, mistakes occurred on ambiguous unsubscribe and compound
play-plus-speed requests. A 0.5 gate increased coverage from 43.9% to 66.7% in this
recording. This is exploratory analysis on the existing corpus, **not a calibrated
66.7% production coverage estimate or independent validation of 0.5**. The hybrid
was not run live at that lower threshold.

## Existing failures found

Both the baseline and hybrid failed the same four case categories:

- **Tuesday's episode, 3/3:** selected an older episode of the correct show.
- **“Skip ahead a bit”, 3/3:** issued playback of the current episode instead of
  returning the expected clarification for an unsupported backend transport request.
- **“Unsubscribe from The Rest Is”, 3/3:** removed The Rest Is History instead of
  distinguishing it from The Rest Is Politics.
- **“Follow that newsletter”, 1/3:** accepted Benedict Evans when two senders were
  waiting and the user had not identified either one.

These were synthetic accounts. Jev sometimes correctly identified ambiguity, but
the current fallback policy then sent the original request to an LLM that guessed.
An explicit ambiguity result should be investigated as a reason to ask a short,
specific clarification directly, rather than always retrying with another model.

## Method and limits

- The adapter only receives the app's normal conversation input. It never sees
  case IDs, expected answers, hidden catalogue entries or grading feedback.
- All configurations use the existing production conversation executor and
  outcome-based grader, with a fresh in-memory database per attempt. Feed fetches,
  directory searches and application mutations are mocked. Provider-hosted web
  search remains real and was charged separately.
- Jev gets six parallel Choice questions: scope, action, episode, subscription,
  waiting newsletter and speed. Missing/ambiguous targets are explicit choices.
  Detailed episode data is in the episode criteria; every question receives the
  request, history, playback context, subscriptions and waiting senders.
- Code annotates Jev's candidate dates with weekdays and latest flags. The
  baseline retains its existing prompt, so this compares two pipelines rather
  than isolating model quality under identical input formatting.
- Jobs were shuffled with seed 42 and concurrency 4. Model IDs, input/output
  usage, probability distributions, tool calls and source hashes are recorded.
- An initial unpaced run hit OpenAI's token-rate limit and was stopped. Its
  results are excluded. The final run spaces OpenAI calls by at least 1.8 seconds;
  measured throttle wait is recorded separately and subtracted from command
  latency. Final results contain no provider errors.
- Command time includes candidate retrieval, API calls and mocked action
  execution, but excludes synthetic database setup and deliberate benchmark
  throttling. It does not measure speech recognition, phone-to-server latency,
  real feed-fetch delays or playback startup.
- Repetitions measure variability over 41 examples, not 123 independent tasks.
  This corpus does not comprehensively cover duration-filtered search, saved-only
  search, viewed-item context, undo or open-ended publication discovery. No
  production traffic distribution or real speech recordings were evaluated.

## Recommendation

Keep the current production model while addressing the ambiguity and date
regressions. The next Jev experiment should test a 0.5–0.7 threshold on **new**
paraphrases and held-out requests, retain explicit ambiguity instead of letting a
fallback guess, and measure against actual production cache behaviour. The
observed direct-action speed improvement is useful; the tested hybrid is not yet
an overall improvement.

## Reproduce and inspect

`make backend-check` passed: frozen dependency sync, Ruff lint/format checks,
type checking, **1,129 backend tests**, and **123 repository-script tests**.
Adapter tests verify real executor/grader outcomes, candidate-ID boundaries,
confidence/compound gates, provider-error fallback and cache-aware costing.

```bash
cd backend
uv run python -m evals.compare_jev --repeat 3 --threshold 0.9 \
  --openai-interval 1.8 --json ../build/jev-evals/comparison.json
```

Requires the existing OpenAI key and `JEV_API_KEY` in the root `.env` or environment.
No key values are written to reports. See [harness documentation](../backend/evals/README.md#jev-comparison-evaluation-only).

Local artifacts:

- [Raw live results](../build/jev-evals/paced-comparison-2026-09-20.json)
- [Cost analysis](../build/jev-evals/analysis.json)
- [Threshold replay](../build/jev-evals/threshold-replay.json)
- [Offline replay script](../build/jev-evals/replay_thresholds.py)
- [Backend verification log](../build/jev-evals/backend-check.log)

The raw run's original summary excluded cache-write premiums and web-search
fees. The cost analysis and tables above include both; the reusable harness now
also includes cache-write pricing. Raw usage and original source hashes remain
unchanged so the recorded experiment can be audited.
