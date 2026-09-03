from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import testflight_distribute as distribute


def test_team_key_claims_carry_the_issuer():
    claims, key_id, key = distribute.token_claims(
        {"ASC_KEY_ID": "TEAMKEY", "ASC_ISSUER_ID": "issuer-uuid", "ASC_KEY_P8_BASE64": "a2V5"}, now=1_000
    )

    assert (key_id, key) == ("TEAMKEY", "key")
    assert claims["iss"] == "issuer-uuid"
    assert "sub" not in claims
    assert claims["exp"] - claims["iat"] == 19 * 60


def test_individual_key_claims_name_the_person_not_the_team():
    claims, key_id, key = distribute.token_claims(
        {
            "ASC_KEY_ID": "TEAMKEY",
            "ASC_ISSUER_ID": "issuer-uuid",
            "ASC_KEY_P8_BASE64": "a2V5",
            "ASC_INDIVIDUAL_KEY_ID": "MYKEY",
            "ASC_INDIVIDUAL_KEY_P8_BASE64": "bWluZQ==",
        },
        now=1_000,
    )

    assert (key_id, key) == ("MYKEY", "mine")
    assert claims["sub"] == "user"
    assert "iss" not in claims


def test_missing_team_key_is_named():
    with pytest.raises(distribute.Failure, match="ASC_ISSUER_ID is not set"):
        distribute.token_claims({"ASC_KEY_ID": "TEAMKEY", "ASC_KEY_P8_BASE64": "a2V5"}, now=1_000)


class FakeSubmissionClient:
    def __init__(self, existing: dict | None, *, refusal: str | None = None):
        self.existing = existing
        self.refusal = refusal
        self.posts: list[str] = []

    def get(self, path: str, **_kwargs) -> dict:
        assert path == "/builds/build-id/betaAppReviewSubmission"
        return {"data": self.existing}

    def post(self, path: str, _body: dict) -> dict:
        self.posts.append(path)
        if self.refusal:
            raise distribute.Failure(self.refusal)
        return {"data": {}}


def test_a_build_already_under_beta_review_is_left_alone(capsys):
    client = FakeSubmissionClient({"attributes": {"betaReviewState": "WAITING_FOR_REVIEW"}})

    distribute.submit_for_review(client, "build-id")

    assert client.posts == []
    assert "already submitted for beta app review (WAITING_FOR_REVIEW)" in capsys.readouterr().out


def test_a_rejected_build_is_submitted_again():
    client = FakeSubmissionClient({"attributes": {"betaReviewState": "REJECTED"}})

    distribute.submit_for_review(client, "build-id")

    assert client.posts == ["/betaAppReviewSubmissions"]


def test_apples_other_word_for_a_duplicate_is_understood():
    refusal = 'POST /betaAppReviewSubmissions -> 422: {"code": "ENTITY_UNPROCESSABLE.INVALID_QC_STATE"}'
    client = FakeSubmissionClient(None, refusal=refusal)

    distribute.submit_for_review(client, "build-id")

    assert client.posts == ["/betaAppReviewSubmissions"]
