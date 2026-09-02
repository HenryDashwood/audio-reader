"""Answering a waiting newsletter sender, and asking for the address, by voice."""

import pytest
from sqlalchemy import select

from audioreader.commands import service
from audioreader.commands.conversation import AssistantDelta, ConversationFinished, converse
from audioreader.commands.intents import Action
from audioreader.config import settings
from audioreader.llm.fake import FakeLLMClient
from audioreader.llm.openai_responses import ResponseCompleted, ResponseTextDelta
from audioreader.models import (
    APPROVAL_APPROVED,
    APPROVAL_BLOCKED,
    APPROVAL_PENDING,
    FEED_SOURCE_EMAIL,
    Episode,
    Feed,
    Subscription,
)


async def waiting(session, user, title: str, address: str, subjects: list[str]) -> Feed:
    feed = Feed(
        url=f"email://{user.id}/{address}",
        title=title,
        description=address,
        source=FEED_SOURCE_EMAIL,
        owner_user_id=user.id,
        approval=APPROVAL_PENDING,
    )
    feed.episodes = [
        Episode(guid=f"{address}-{index}", title=subject, content_html=f"<p>{subject}</p>")
        for index, subject in enumerate(subjects)
    ]
    session.add(feed)
    await session.commit()
    return feed


@pytest.fixture
async def levine(session, user) -> Feed:
    return await waiting(
        session, user, "Matt Levine", "noreply@news.bloomberg.com", ["Money Stuff: A", "Money Stuff: B"]
    )


@pytest.fixture
async def evans(session, user) -> Feed:
    return await waiting(session, user, "Benedict Evans", "list@ben-evans.com", ["Benedict's Newsletter: No. 658"])


@pytest.fixture
def newsletters_enabled(monkeypatch):
    monkeypatch.setattr(settings, "inbound_email_domain", "magpieinbox.com")
    monkeypatch.setattr(settings, "inbound_email_secret", "secret")


def decision(action: str, **fields) -> dict:
    return {"action": action, "spoken_response": "", **fields}


async def subscribed_ids(session, user) -> set[int]:
    return set(await session.scalars(select(Subscription.feed_id).where(Subscription.user_id == user.id)))


class TestPrompt:
    async def test_waiting_senders_are_listed_apart_from_episodes(self, session, user, levine, evans):
        llm = FakeLLMClient(decision("unknown", spoken_response="Which one?"))

        await service.interpret(session, llm, user=user, transcript="anything")

        prompt = llm.calls[0]["user"]
        assert "Newsletter senders waiting for her answer (use newsletter_id):" in prompt
        assert f"[newsletter {levine.id}] Matt Levine — 2 messages — latest: Money Stuff: B" in prompt
        assert f"[newsletter {evans.id}] Benedict Evans — 1 message — latest: Benedict's Newsletter: No. 658" in prompt
        assert prompt.index("Newsletter senders") < prompt.index("Episodes and articles she subscribes to:")

    async def test_nothing_waiting_means_no_section(self, session, user):
        llm = FakeLLMClient(decision("unknown", spoken_response="Which one?"))

        await service.interpret(session, llm, user=user, transcript="anything")

        assert "Newsletter senders" not in llm.calls[0]["user"]

    async def test_the_prompt_explains_the_actions(self):
        assert "approve_newsletter" in service.SYSTEM_PROMPT
        assert "block_newsletter" in service.SYSTEM_PROMPT
        assert "newsletter_address" in service.SYSTEM_PROMPT


class TestApprove:
    async def test_by_number(self, session, user, levine, evans):
        llm = FakeLLMClient(decision("approve_newsletter", newsletter_id=levine.id))

        result = await service.interpret(session, llm, user=user, transcript="yes, follow Matt Levine")

        assert result.action is Action.SUBSCRIBED
        assert result.spoken_response == "Following Matt Levine. Its 2 messages are in Latest."
        assert not result.expects_reply
        assert await subscribed_ids(session, user) == {levine.id}
        assert levine.approval == APPROVAL_APPROVED
        assert evans.approval == APPROVAL_PENDING

    async def test_by_name_when_the_number_is_missing(self, session, user, levine, evans):
        llm = FakeLLMClient(decision("approve_newsletter", search_query="benedict evans"))

        result = await service.interpret(session, llm, user=user, transcript="follow Benedict Evans")

        assert result.action is Action.SUBSCRIBED
        assert result.spoken_response == "Following Benedict Evans. Its message is in Latest."
        assert await subscribed_ids(session, user) == {evans.id}

    async def test_the_only_waiting_sender_needs_no_name(self, session, user, levine):
        llm = FakeLLMClient(decision("approve_newsletter"))

        result = await service.interpret(session, llm, user=user, transcript="follow it")

        assert result.action is Action.SUBSCRIBED
        assert "Matt Levine" in result.spoken_response

    async def test_two_waiting_and_no_name_asks(self, session, user, levine, evans):
        llm = FakeLLMClient(decision("approve_newsletter"))

        result = await service.interpret(session, llm, user=user, transcript="follow that newsletter")

        assert result.action is Action.UNKNOWN
        assert result.expects_reply
        assert "Matt Levine" in result.spoken_response and "Benedict Evans" in result.spoken_response
        assert await subscribed_ids(session, user) == set()

    async def test_a_number_that_is_not_waiting_is_never_a_guess(self, session, user, levine, evans):
        llm = FakeLLMClient(decision("approve_newsletter", newsletter_id=levine.episodes[0].id + 1000))

        result = await service.interpret(session, llm, user=user, transcript="follow it")

        assert result.action is Action.UNKNOWN
        assert result.expects_reply
        assert await subscribed_ids(session, user) == set()

    async def test_nothing_waiting(self, session, user):
        llm = FakeLLMClient(decision("approve_newsletter", search_query="matt levine"))

        result = await service.interpret(session, llm, user=user, transcript="follow Matt Levine")

        assert result.action is Action.UNKNOWN
        assert result.spoken_response == "No newsletters are waiting for your answer."
        assert not result.expects_reply

    async def test_only_her_own_senders(self, session, user, levine, evans):
        # Another account's pending feed is never offered, and its number is
        # refused if the model somehow produces it.
        from audioreader.models import User

        other = User(display_name="Someone Else")
        session.add(other)
        await session.commit()
        theirs = await waiting(session, other, "Their Sender", "them@example.com", ["Hello"])
        llm = FakeLLMClient(decision("approve_newsletter", newsletter_id=theirs.id))

        result = await service.interpret(session, llm, user=user, transcript="follow it")

        assert result.action is Action.UNKNOWN
        assert theirs.approval == APPROVAL_PENDING


class TestBlock:
    async def test_by_number(self, session, user, levine, evans):
        llm = FakeLLMClient(decision("block_newsletter", newsletter_id=evans.id))

        result = await service.interpret(session, llm, user=user, transcript="block Benedict Evans")

        assert result.action is Action.UNSUBSCRIBED
        assert result.spoken_response == "Blocked Benedict Evans. Anything it sends from now on is dropped."
        assert evans.approval == APPROVAL_BLOCKED
        assert (await session.scalars(select(Episode).where(Episode.feed_id == evans.id))).all() == []
        assert levine.approval == APPROVAL_PENDING

    async def test_two_waiting_and_no_name_asks(self, session, user, levine, evans):
        llm = FakeLLMClient(decision("block_newsletter"))

        result = await service.interpret(session, llm, user=user, transcript="block it")

        assert result.action is Action.UNKNOWN
        assert result.expects_reply
        assert levine.approval == APPROVAL_PENDING and evans.approval == APPROVAL_PENDING


class TestAddress:
    async def test_says_the_address_word_by_word(self, session, user, newsletters_enabled):
        user.inbound_token = "hefty-prism-bolt"
        await session.commit()
        llm = FakeLLMClient(decision("newsletter_address"))

        result = await service.interpret(session, llm, user=user, transcript="what's my newsletter address")

        assert result.action is Action.UNKNOWN
        assert not result.expects_reply
        assert result.spoken_response == (
            "Your newsletter address is hefty, prism, bolt, with hyphens between the words, "
            "at magpieinbox dot com. It is also in Settings."
        )

    async def test_mints_one_the_first_time(self, session, user, newsletters_enabled):
        llm = FakeLLMClient(decision("newsletter_address"))

        result = await service.interpret(session, llm, user=user, transcript="what's my newsletter address")

        assert user.inbound_token is not None
        assert user.inbound_token.split("-")[0] in result.spoken_response

    async def test_an_older_letter_address_is_spelled(self):
        assert service.spoken_address("nwxtemygmy@magpieinbox.com") == (
            "n, w, x, t, e, m, y, g, m, y, at magpieinbox dot com"
        )

    async def test_not_set_up(self, session, user):
        llm = FakeLLMClient(decision("newsletter_address"))

        result = await service.interpret(session, llm, user=user, transcript="what's my newsletter address")

        assert result.spoken_response == "Newsletters by email are not set up on this server yet."
        assert user.inbound_token is None


class ScriptedResponsesClient:
    def __init__(self, rounds):
        self.rounds = list(rounds)
        self.requests = []

    async def stream(self, *, instructions, input_items, tools=None):
        self.requests.append((instructions, list(input_items), list(tools or [])))
        for event in self.rounds.pop(0):
            yield event


def tool_call(name: str, arguments: str) -> ResponseCompleted:
    return ResponseCompleted(
        {"output": [{"type": "function_call", "name": name, "call_id": "call_1", "arguments": arguments}]}
    )


class TestStreamedConversation:
    async def test_waiting_senders_are_in_the_context_and_the_tools_offered(self, session, user, levine):
        client = ScriptedResponsesClient([[tool_call("approve_newsletter", f'{{"newsletter_id":{levine.id}}}')]])

        events = [event async for event in converse(session, client, transcript="yes follow it", user=user)]

        instructions, items, tools = client.requests[0]
        assert "approve_newsletter" in instructions
        assert f"[{levine.id}] Matt Levine — noreply@news.bloomberg.com — 2 message(s)" in items[-1]["content"]
        assert {tool.get("name") for tool in tools} >= {
            "approve_newsletter",
            "block_newsletter",
            "read_newsletter_address",
        }
        finished = next(event for event in events if isinstance(event, ConversationFinished))
        assert finished.result.action is Action.SUBSCRIBED
        assert "".join(e.text for e in events if isinstance(e, AssistantDelta)) == (
            "Following Matt Levine. Its 2 messages are in Latest."
        )
        assert await subscribed_ids(session, user) == {levine.id}

    async def test_block_tool(self, session, user, evans):
        client = ScriptedResponsesClient([[tool_call("block_newsletter", f'{{"newsletter_id":{evans.id}}}')]])

        events = [event async for event in converse(session, client, transcript="block it", user=user)]

        finished = next(event for event in events if isinstance(event, ConversationFinished))
        assert finished.result.action is Action.UNSUBSCRIBED
        assert evans.approval == APPROVAL_BLOCKED

    async def test_a_number_that_is_not_waiting_is_reported_to_the_model(self, session, user, levine):
        client = ScriptedResponsesClient(
            [
                [tool_call("approve_newsletter", '{"newsletter_id":999999}')],
                [
                    ResponseTextDelta("That one is not waiting."),
                    ResponseCompleted(
                        {
                            "output": [
                                {
                                    "type": "message",
                                    "content": [{"type": "output_text", "text": "That one is not waiting."}],
                                }
                            ]
                        }
                    ),
                ],
            ]
        )

        events = [event async for event in converse(session, client, transcript="follow it", user=user)]

        finished = next(event for event in events if isinstance(event, ConversationFinished))
        assert finished.result.action is Action.UNKNOWN
        assert await subscribed_ids(session, user) == set()
        # The second round saw the tool's refusal.
        assert '"ok": false' in client.requests[1][1][-1]["output"]

    async def test_address_tool(self, session, user, newsletters_enabled):
        user.inbound_token = "hefty-prism-bolt"
        await session.commit()
        client = ScriptedResponsesClient([[tool_call("read_newsletter_address", "{}")]])

        events = [event async for event in converse(session, client, transcript="what's my address", user=user)]

        finished = next(event for event in events if isinstance(event, ConversationFinished))
        assert finished.result.action is Action.UNKNOWN
        assert finished.result.spoken_response.startswith("Your newsletter address is hefty, prism, bolt")

    async def test_no_section_when_nothing_is_waiting(self, session, user):
        client = ScriptedResponsesClient(
            [
                [
                    ResponseTextDelta("Hello?"),
                    ResponseCompleted(
                        {"output": [{"type": "message", "content": [{"type": "output_text", "text": "Hello?"}]}]}
                    ),
                ]
            ]
        )

        [event async for event in converse(session, client, transcript="hello", user=user)]

        assert "waiting for an answer" not in client.requests[0][1][-1]["content"]
