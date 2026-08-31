from audioreader.commands.conversation import AssistantDelta, ConversationFinished, converse
from audioreader.commands.intents import Action
from audioreader.llm.openai_responses import ResponseCompleted, ResponseTextDelta
from audioreader.models import Feed


class ScriptedResponsesClient:
    def __init__(self, rounds):
        self.rounds = list(rounds)
        self.requests = []

    async def stream(self, *, instructions, input_items, tools=None):
        self.requests.append((instructions, list(input_items), list(tools or [])))
        for event in self.rounds.pop(0):
            yield event


async def test_model_can_resolve_imperfect_dictation_then_subscribe(session, user, monkeypatch):
    async def subscribe(_session, url, _user):
        assert url == "https://semianalysis.com/feed"
        return Feed(id=42, url=url, title="SemiAnalysis")

    monkeypatch.setattr("audioreader.commands.conversation.feed_service.subscribe", subscribe)
    client = ScriptedResponsesClient(
        [
            [
                ResponseCompleted(
                    {
                        "output": [
                            {
                                "type": "function_call",
                                "name": "subscribe_to_feed",
                                "call_id": "call_1",
                                "arguments": '{"feed_url":"https://semianalysis.com/feed"}',
                            }
                        ]
                    }
                )
            ]
        ]
    )

    events = [
        event
        async for event in converse(
            session,
            client,
            transcript="Subscribe to semi analysis sub stack",
            user=user,
        )
    ]

    assert "".join(event.text for event in events if isinstance(event, AssistantDelta)) == (
        "Subscribed to SemiAnalysis."
    )
    finished = next(event for event in events if isinstance(event, ConversationFinished))
    assert finished.result.action is Action.SUBSCRIBED
    assert finished.result.spoken_response == "Subscribed to SemiAnalysis."
    assert client.requests[0][1][-1]["content"].startswith("Today is")
    assert 'User said: "Subscribe to semi analysis sub stack"' in client.requests[0][1][-1]["content"]
    assert len(client.requests) == 1


async def test_model_question_is_streamed_and_reopens_microphone(session, user):
    client = ScriptedResponsesClient(
        [
            [
                ResponseTextDelta("Do you mean SemiAnalysis, "),
                ResponseTextDelta("the semiconductor research firm?"),
                ResponseCompleted(
                    {
                        "output": [
                            {
                                "type": "message",
                                "content": [
                                    {
                                        "type": "output_text",
                                        "text": "Do you mean SemiAnalysis, the semiconductor research firm?",
                                    }
                                ],
                            }
                        ]
                    }
                ),
            ]
        ]
    )

    events = [event async for event in converse(session, client, transcript="subscribe to analysis", user=user)]
    finished = next(event for event in events if isinstance(event, ConversationFinished))
    assert finished.result.action is Action.UNKNOWN
    assert finished.result.expects_reply is True
