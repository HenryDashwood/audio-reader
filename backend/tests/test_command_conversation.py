from audioreader.commands.conversation import AssistantDelta, ConversationFinished, converse
from audioreader.commands.intents import Action
from audioreader.llm.openai_responses import ResponseCompleted, ResponseTextDelta
from audioreader.models import Feed
from audioreader.routers.commands import command_stream
from audioreader.schemas import CommandRequest


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


async def test_saloni_dattani_regression_uses_web_result_then_subscribes(session, user, monkeypatch):
    """The real failed transcript should remain solvable in one user turn.

    The hosted search itself is OpenAI's concern; this protects the app seam
    around it: a web result can lead to a custom-domain publication, its feed
    can be inspected, and the verified feed can then be subscribed without a
    clarification or an invented ``salonidattani.substack.com`` hostname.
    """

    async def resolve(url):
        assert url == "https://www.scientificdiscovery.dev"
        return "https://www.scientificdiscovery.dev/feed", type("Parsed", (), {"title": "Scientific Discovery"})()

    async def subscribe(_session, url, _user):
        assert url == "https://www.scientificdiscovery.dev/feed"
        return Feed(id=43, url=url, title="Scientific Discovery")

    monkeypatch.setattr("audioreader.commands.conversation.resolve_feed", resolve)
    monkeypatch.setattr("audioreader.commands.conversation.feed_service.subscribe", subscribe)
    client = ScriptedResponsesClient(
        [
            [
                ResponseCompleted(
                    {
                        "output": [
                            {
                                "type": "web_search_call",
                                "id": "search_1",
                                "status": "completed",
                            },
                            {
                                "type": "function_call",
                                "name": "inspect_publication",
                                "call_id": "call_1",
                                "arguments": '{"url":"https://www.scientificdiscovery.dev"}',
                            },
                        ]
                    }
                )
            ],
            [
                ResponseCompleted(
                    {
                        "output": [
                            {
                                "type": "function_call",
                                "name": "subscribe_to_feed",
                                "call_id": "call_2",
                                "arguments": ('{"feed_url":"https://www.scientificdiscovery.dev/feed"}'),
                            }
                        ]
                    }
                )
            ],
        ]
    )

    events = [
        event
        async for event in converse(
            session,
            client,
            transcript="Subscribe to Saloni attorney's Substack",
            user=user,
        )
    ]

    finished = next(event for event in events if isinstance(event, ConversationFinished))
    assert finished.result.action is Action.SUBSCRIBED
    assert finished.result.spoken_response == "Subscribed to Scientific Discovery."
    assert len(client.requests) == 2

    tools = client.requests[0][2]
    podcast_tool = next(tool for tool in tools if tool.get("name") == "search_podcast_directory")
    inspect_tool = next(tool for tool in tools if tool.get("name") == "inspect_publication")
    assert "only when the requested thing is a podcast" in podcast_tool["description"]
    assert "never guess or invent a hostname" in inspect_tool["description"]

    second_round_input = client.requests[1][1]
    assert any(item.get("type") == "web_search_call" for item in second_round_input)
    assert any(
        item.get("type") == "function_call_output"
        and "https://www.scientificdiscovery.dev/feed" in item.get("output", "")
        for item in second_round_input
    )


async def test_stream_trace_records_the_answer_and_tool_chain(capfire, session, user, monkeypatch):
    async def subscribe(_session, url, _user):
        return Feed(id=44, url=url, title="Scientific Discovery")

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
                                "arguments": ('{"feed_url":"https://www.scientificdiscovery.dev/feed"}'),
                            }
                        ]
                    }
                )
            ]
        ]
    )

    response = await command_stream(
        CommandRequest(transcript="Subscribe to Saloni Dattani's Substack"),
        session,
        client,
        user,
    )
    chunks = [chunk async for chunk in response.body_iterator]
    body = b"".join(chunk.encode() if isinstance(chunk, str) else bytes(chunk) for chunk in chunks)
    assert b'"action":"subscribed"' in body

    spans = capfire.exporter.exported_spans_as_dict()
    command = next(span for span in spans if span["name"] == "command")
    assert command["attributes"]["pipeline"] == "conversation"
    assert command["attributes"]["action"] == "subscribed"
    assert command["attributes"]["assistant_response"] == "Subscribed to Scientific Discovery."

    tool = next(span for span in spans if span["name"] == "conversation tool")
    assert tool["attributes"]["tool_name"] == "subscribe_to_feed"
    assert tool["attributes"]["tool_feed_url"] == "https://www.scientificdiscovery.dev/feed"
    assert tool["attributes"]["tool_result_status"] == "subscribed"
    assert tool["attributes"]["terminal_action"] == "subscribed"
