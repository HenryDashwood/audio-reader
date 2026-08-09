from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.llm.fake import FakeLLMClient


def speed_decision(speed) -> dict:
    return {"action": "set_speed", "speed": speed, "spoken_response": ""}


class TestSetSpeedByVoice:
    async def test_returns_the_speed_for_the_app_to_apply(self, session, user):
        llm = FakeLLMClient(speed_decision(1.5))
        result = await service.interpret(
            session, llm, user=user, transcript="play at one and a half speed"
        )

        assert result.action == Action.SET_SPEED
        assert result.speed == 1.5
        assert "1.5 times" in result.spoken_response

    async def test_normal_speed_is_spoken_plainly(self, session, user):
        llm = FakeLLMClient(speed_decision(1.0))
        result = await service.interpret(session, llm, user=user, transcript="normal speed")
        assert result.speed == 1.0
        assert result.spoken_response == "Normal speed."

    async def test_whole_multiples_have_no_decimal_point(self, session, user):
        llm = FakeLLMClient(speed_decision(2.0))
        result = await service.interpret(session, llm, user=user, transcript="double speed")
        assert result.spoken_response == "2 times speed."

    async def test_model_noise_is_rounded_to_a_quarter(self, session, user):
        llm = FakeLLMClient(speed_decision(1.499999))
        result = await service.interpret(session, llm, user=user, transcript="one and a half")
        assert result.speed == 1.5

    async def test_missing_speed_asks_instead(self, session, user):
        llm = FakeLLMClient(speed_decision(None))
        result = await service.interpret(session, llm, user=user, transcript="change the speed")
        assert result.action == Action.UNKNOWN
        assert result.speed is None
        assert result.spoken_response

    async def test_absurd_speed_is_rejected(self, session, user):
        llm = FakeLLMClient(speed_decision(10))
        result = await service.interpret(session, llm, user=user, transcript="ten times speed")
        assert result.action == Action.UNKNOWN


class TestSetSpeedEndpoint:
    async def test_response_carries_the_speed(self, client, fake_llm):
        fake_llm.respond_with(speed_decision(1.25))
        response = await client.post("/command", json={"transcript": "a bit faster please"})

        assert response.status_code == 200
        body = response.json()
        assert body["action"] == "set_speed"
        assert body["speed"] == 1.25
        assert body["episode"] is None
