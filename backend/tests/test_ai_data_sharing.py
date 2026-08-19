from audioreader.models import utcnow
from audioreader.routers.auth import AI_DATA_SHARING_CONSENT_VERSION


class TestCommandConsent:
    async def test_command_is_refused_before_the_model_without_permission(self, client, fake_llm, user):
        user.ai_consent_version = None
        user.ai_data_sharing_consented_at = None

        response = await client.post("/command", json={"transcript": "play the latest"})

        assert response.status_code == 403
        assert "allow AI data sharing" in response.json()["detail"]["spoken_response"]
        assert fake_llm.calls == []

    async def test_an_old_consent_version_is_not_silently_reused(self, client, fake_llm, user):
        user.ai_consent_version = AI_DATA_SHARING_CONSENT_VERSION - 1
        user.ai_data_sharing_consented_at = utcnow()

        response = await client.post("/command", json={"transcript": "play the latest"})

        assert response.status_code == 403
        assert fake_llm.calls == []
