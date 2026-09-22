"""Check the experimental adapter and measurement without calling paid APIs."""

import json

import httpx
import pytest

from audioreader.llm.client import LLMError
from audioreader.llm.openai_responses import ResponseCompleted, ResponseTextDelta
from evals.cases import by_id
from evals.compare_jev import percentile, token_cost
from evals.grading import Grade
from evals.jev import ENDPOINT, JevClient, parse_input, questions_for, select_call
from evals.runner import run_case
from evals.world import build_world, stub_world


def input_items():
    return [
        {
            "role": "user",
            "content": """Today is 2026-09-20.
User said: "Play Tuesday's one"
Subscriptions (valid IDs for unsubscribe):
[7] A show — https://show.example/feed
Available episodes/articles (valid IDs for playback or filing):
[42] Older episode — A show — 2026-09-08
    An older description.
[43] Newer episode — A show — 2026-09-15
    A newer description.
Listening details (unknown duration must not be guessed):
[42] kind=audio; duration_seconds=1200; completed=False
[43] kind=audio; duration_seconds=None; completed=False
""",
        }
    ]


def answers_for(questions):
    choices = {"scope": "single", "action": "play_episode", "episode": "43"}
    return {key: {"choice": choices.get(key, "none"), "confidence": 1.0, "probabilities": {}} for key in questions}


def test_prompt_parsing_keeps_date_math_and_id_namespaces_in_code():
    state = parse_input(input_items())
    assert set(state["subscriptions"]) == {"7"}
    assert set(state["episodes"]) == {"42", "43"}
    assert state["episodes"]["42"]["weekday"] == "Tuesday"
    assert not state["episodes"]["42"]["latest_in_show"]
    assert state["episodes"]["43"]["latest_overall"]
    assert "duration_seconds=None" in state["episodes"]["43"]["listening_state"]


@pytest.mark.parametrize("reason", ["compound", "none", "uncertain", "unknown_id"])
def test_no_action_when_compound_unmatched_uncertain_or_outside_candidates(reason):
    state = parse_input(input_items())
    answers = answers_for(questions_for(state))
    if reason == "compound":
        answers["scope"]["choice"] = "compound"
    elif reason == "none":
        answers["episode"]["choice"] = "none"
    elif reason == "uncertain":
        answers["episode"]["confidence"] = 0.89
    else:
        answers["episode"]["choice"] = "999"
    assert select_call(state, answers, 0.9)[0] is None


async def test_api_usage_and_choice_validation(respx_mock):
    state = parse_input(input_items())
    questions = questions_for(state)
    payload = {"model": "jev-1.13.0", "answers": answers_for(questions), "usage": {"input_tokens": 200}}
    route = respx_mock.post(ENDPOINT).mock(return_value=httpx.Response(200, json=payload))
    client = JevClient(api_key="test-key")
    await client.evaluate({"request": state["request"]}, questions)
    assert client.calls[0]["usage"] == {"input_tokens": 200}
    assert route.calls.last.request.headers["authorization"] == "Bearer test-key"
    payload["answers"]["episode"]["choice"] = "999"
    route.mock(return_value=httpx.Response(200, json=payload))
    with pytest.raises(LLMError):
        await client.evaluate({}, questions)


async def test_provider_failure_falls_back_before_any_action(respx_mock):
    respx_mock.post(ENDPOINT).mock(return_value=httpx.Response(529))

    class Fallback:
        async def stream(self, **kwargs):
            assert kwargs["input_items"] == input_items()
            yield ResponseTextDelta("Which episode?")
            yield ResponseCompleted({"output": []})

    client = JevClient(api_key="test-key", fallback=Fallback())
    events = [event async for event in client.stream(instructions="", input_items=input_items())]
    assert client.delegated
    assert client.decision["reason"] == "provider_or_input_error"
    assert events[0].text == "Which episode?"


@pytest.mark.parametrize("title,expected", [("Dark Matter", Grade.PASS), ("Dark Energy", Grade.FAIL)])
async def test_real_executor_and_grader_judge_jev_selected_episode(monkeypatch, title, expected):
    async def evaluate(self, state, questions):
        # The model adapter sees no case ID, grade, expected GUID or synthetic world.
        assert set(state) == {"request", "history", "context", "subscriptions", "newsletters"}
        answers = answers_for(questions)
        answers["episode"]["choice"] = next(
            key
            for key, value in questions["episode"]["criteria"].items()
            if isinstance(value, dict) and value["title"] == title
        )
        return answers

    monkeypatch.setattr(JevClient, "evaluate", evaluate)
    world = build_world()
    with stub_world(world):
        result = await run_case(
            by_id("recent-by-topic"), world, JevClient(api_key="test-key"), pipeline="conversation"
        )
    assert result.grade is expected
    assert result.command_seconds > 0
    assert result.command_seconds < result.seconds


@pytest.mark.parametrize(
    ("model", "cached_cost", "write_cost", "uncached_cost"),
    [
        ("gpt-5.6-luna", 0.000176, 0.000181, 0.00032),
        ("gpt-6-luna", 0.000078, 0.0000805, 0.00015),
    ],
)
def test_cost_includes_cache_discount_and_free_jev_output(monkeypatch, model, cached_cost, write_cost, uncached_cost):
    from audioreader.config import settings

    monkeypatch.setattr(settings, "openai_model", model)
    assert token_cost({"provider": "jev", "usage": {"input_tokens": 1000, "output_tokens": 5000}}) == 0.000042
    call = {
        "provider": "openai",
        "usage": {"input_tokens": 1000, "input_tokens_details": {"cached_tokens": 800}, "output_tokens": 100},
    }
    assert token_cost(call) == pytest.approx(cached_cost)
    call["usage"]["input_tokens_details"]["cache_write_tokens"] = 100
    assert token_cost(call) == pytest.approx(write_cost)
    assert token_cost(call, ignore_cache=True) == pytest.approx(uncached_cost)
    assert token_cost({"provider": "jev"}) is None
    assert percentile([1, 2, 3], 0.95) == 3


def test_filing_emits_the_original_executor_contract():
    state = parse_input(input_items())
    answers = answers_for(questions_for(state))
    answers["action"]["choice"] = "dismiss"
    call, reason, _ = select_call(state, answers, 0.9)
    assert reason == "accepted"
    assert call is not None
    assert call["name"] == "file_episode"
    assert json.loads(call["arguments"]) == {"continue_request": False, "episode_id": 43, "action": "dismiss"}
