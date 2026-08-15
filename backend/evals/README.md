# Voice command evals

A corpus of things she might say, each paired with what should happen. Run it
against a real model to find out whether a prompt change, a model change or a
settings change made the app better or worse at understanding her.

Everything except the model call is stubbed, so a run is reproducible, needs no
database, and never touches a real feed or the podcast directory.

```bash
cd backend
uv run python -m evals                                # everything
uv run python -m evals play back-catalogue            # cases matching those words
uv run python -m evals --model deepseek/deepseek-v4-flash
uv run python -m evals --candidates 200 --repeat 3
uv run python -m evals --json runs/luna.json
```

It costs money — one model call per case, at least. It exits non-zero when
anything fails or errors, so it can gate a release later.

## What a run tells you

Four verdicts, because for a listener who cannot see the screen they are four
genuinely different things:

| | |
| --- | --- |
| **pass** | it did what she asked |
| **asked** | it asked a question instead. Not right, but safe — she says one more sentence and gets there |
| **fail** | it did something else, said nothing, or answered in a language the phone's English voice cannot read out |
| **error** | the provider returned nothing usable. Kept separate so a flaky upstream is not mistaken for a bad model |

Failures print with the reason the case exists, so a red line six months from
now still explains itself.

## The world

`world.py` holds a synthetic library shaped like hers: In Our Time with a
hundred-odd episodes going back two years, two chattier podcasts, and a blog
that posts twice a week. Two more shows and a second blog exist only in the
stubbed directory, so asking for them exercises discovery.

Dates count back from today, so "the latest" and "Tuesday's one" keep meaning
what they mean. Pin them with `--reference-date` when comparing two runs
exactly.

The crowding is deliberate. Four subscriptions publishing six times a week
means the sixty newest items — the default `command_candidate_limit` — reach
back only about twelve weeks. Everything older used to be invisible to the
model however precisely she named it, which is what this corpus was written to
catch; `command_search_limit` now adds older episodes matching her words to
that window. Run with `--candidates` and `--search 0` to see the old behaviour.

## Adding a case

The valuable cases are the ones that come from something going wrong. Add the
case first, watch it fail, then fix it.

```python
Case(
    id="deep-catalogue-by-topic",
    said="Play the In Our Time episode about Athelstan",
    expect=Expect(Action.PLAY_EPISODE, episode=_guid("in_our_time", "Æthelstan")),
    why="Reported from real use: it played a different In Our Time episode …",
    tags=("play", "back-catalogue", "regression"),
    never=(_latest("astral_codex_ten"),),
)
```

- `expect` is written in terms of what the **app did** — which episode started,
  which feed got subscribed — not what the model replied. Subscriptions are
  compared against the database either side of the call, so a model that says
  "Subscribed!" without subscribing anything fails.
- `why` is required. It is printed with every failure.
- `never` lists outcomes that are wrong however plausible they look.
- `question_is_acceptable=False` where a question is itself the bug.
- If the episode you want is not in `world.py`, add it there — and put it near
  the top of its show's list if the case needs it to be reachable.

`tests/test_evals.py` checks the harness itself — the world, the stubs and the
grader — with no model and no money. That runs in the ordinary suite.

## What is not covered

- **Transport and the sleep timer.** "Pause", "skip", "stop in twenty minutes"
  are matched on the phone so they work with no signal, and they have their own
  tests in `ios/HearfulTests/`. The one thing the corpus does check is that
  "play the one about sleep" is a play request — that is a backend decision.
- **Speech recognition.** Cases are the text a recogniser produced, not audio.
  Mishearings are worth adding as cases in their own right ("Athelstan" for
  "Æthelstan" is one).
- **Token cost.** Model calls per case are counted; tokens are not. To compare
  two models on price, send `build_prompt`'s output to each and read `usage`
  off the response — one command is about 3,500 input tokens against 45
  output, so the input price is very nearly the only one that matters.
- **Feed discovery over the open web.** The world is closed, so discovery of a
  publication by name can only resolve to something defined in `world.py`. The
  domain-spelling path is covered; open-ended web search is not.
