from __future__ import annotations

import json
import sys
from pathlib import Path

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import play_upload as upload


@pytest.fixture(scope="module")
def key() -> dict:
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return {"type": "service_account", "client_email": "uploader@magpie.iam.gserviceaccount.com",
            "private_key": pem.decode(), "private_key_id": "key-1", "_public": private.public_key()}


def test_assertion_is_a_short_lived_token_request_for_the_publisher_scope(key):
    token = upload.assertion(key, now=1_000)
    claims = jwt.decode(token, key["_public"], algorithms=["RS256"], audience=upload.TOKEN_URL,
                        options={"verify_exp": False, "verify_iat": False})
    assert claims["iss"] == key["client_email"]
    assert claims["scope"] == upload.SCOPE
    assert claims["exp"] - claims["iat"] == 3600
    assert jwt.get_unverified_header(token)["kid"] == "key-1"


def test_key_comes_from_environment_then_gradle_properties_then_default(tmp_path, key):
    stored = {k: v for k, v in key.items() if not k.startswith("_")}
    file = tmp_path / "key.json"; file.write_text(json.dumps(stored))
    properties = tmp_path / "gradle.properties"
    properties.write_text(f"MAGPIE_RELEASE_KEY_ALIAS=x\nMAGPIE_PLAY_SERVICE_ACCOUNT={file}\n")
    missing = tmp_path / "missing.json"

    assert upload.service_account({"MAGPIE_PLAY_SERVICE_ACCOUNT_JSON": json.dumps(stored)}, properties, missing)["client_email"]
    assert upload.service_account({"MAGPIE_PLAY_SERVICE_ACCOUNT": str(file)}, tmp_path / "none", missing)["client_email"]
    assert upload.service_account({}, properties, missing)["client_email"]
    with pytest.raises(upload.Failure, match="no Play service-account key"):
        upload.service_account({}, tmp_path / "none", missing)


def test_a_key_that_is_not_a_service_account_is_refused(tmp_path):
    with pytest.raises(upload.Failure, match="not a service-account key"):
        upload.service_account({"MAGPIE_PLAY_SERVICE_ACCOUNT_JSON": json.dumps({"type": "authorized_user"})})


def test_release_notes_are_per_language_and_within_plays_limit(tmp_path):
    (tmp_path / "en-GB.txt").write_text("Fixes saving.\n")
    assert upload.release_notes(tmp_path) == [{"language": "en-GB", "text": "Fixes saving."}]
    (tmp_path / "en-US.txt").write_text("x" * 501)
    with pytest.raises(upload.Failure, match="501 characters"):
        upload.release_notes(tmp_path)


@pytest.mark.parametrize(
    ("draft", "rollout", "expected"),
    [(False, None, {"status": "completed"}), (True, None, {"status": "draft"}),
     (False, 0.2, {"status": "inProgress", "userFraction": 0.2})],
)
def test_release_status(draft, rollout, expected):
    body = upload.release(3, "1.0.2", [], draft=draft, rollout=rollout)
    assert body["versionCodes"] == ["3"] and body["name"] == "3 (1.0.2)"
    assert {k: v for k, v in body.items() if k in ("status", "userFraction")} == expected


class FakeClient:
    def __init__(self, fail_on: str | None = None, error: str = "boom"):
        self.calls: list[tuple[str, str]] = []
        self.fail_on, self.error = fail_on, error
        self.track_body: dict | None = None

    def request(self, method, url, **kwargs):
        path = url.split(upload.PACKAGE, 1)[-1]
        self.calls.append((method, path))
        if self.fail_on and self.fail_on in path and method != "DELETE":
            raise upload.Failure(self.error)
        if path == "/edits" and method == "POST":
            return {"id": "e1"}
        if path.endswith("/apks") and method == "GET":
            return {"apks": [{"versionCode": 3, "binary": {"versionName": "1.0.2"}}]}
        if "/tracks/" in path:
            self.track_body = kwargs["json"]
        return {}

    def upload(self, url, path):
        self.request("POST", url)
        return {"versionCode": 3} if url.endswith("/bundles") else {}


def test_publish_uploads_attaches_assigns_and_commits_one_edit(tmp_path):
    bundle = tmp_path / "app.aab"; bundle.write_bytes(b"aab")
    mapping = tmp_path / "mapping.txt"; mapping.write_text("map")
    client = FakeClient()
    notes = [{"language": "en-GB", "text": "Notes"}]
    assert upload.publish(client, track="internal", bundle=bundle, mapping=mapping, notes=notes,
                          draft=False, rollout=None, log=lambda _: None) == 3
    assert [c for c in client.calls if c[0] != "GET"] == [
        ("POST", "/edits"), ("POST", "/edits/e1/bundles"), ("POST", "/edits/e1/apks/3/deobfuscationFiles/proguard"),
        ("PUT", "/edits/e1/tracks/internal"), ("POST", "/edits/e1:commit")]
    assert client.track_body == {"track": "internal", "releases": [
        {"name": "3 (1.0.2)", "versionCodes": ["3"], "releaseNotes": notes, "status": "completed"}]}


def test_a_failed_step_abandons_the_edit_without_committing(tmp_path):
    bundle = tmp_path / "app.aab"; bundle.write_bytes(b"aab")
    client = FakeClient(fail_on="/tracks/")
    with pytest.raises(upload.Failure, match="boom"):
        upload.publish(client, track="alpha", bundle=bundle, mapping=None, notes=[], draft=False, rollout=None, log=lambda _: None)
    assert ("DELETE", "/edits/e1") in client.calls
    assert not any(path.endswith(":commit") for _, path in client.calls)


def test_a_draft_app_refusal_says_how_to_proceed(tmp_path):
    bundle = tmp_path / "app.aab"; bundle.write_bytes(b"aab")
    client = FakeClient(fail_on=":commit", error="Only releases with status draft may be created on draft app.")
    with pytest.raises(upload.Failure, match="DRAFT=1"):
        upload.publish(client, track="internal", bundle=bundle, mapping=None, notes=[], draft=False, rollout=None, log=lambda _: None)


@pytest.mark.parametrize(
    ("args", "message"),
    [(["--track", "production"], "--confirm-production"),
     (["--rollout", "0.5"], "only for production"),
     (["--track", "production", "--confirm-production", "--rollout", "1.5"], "between 0 and 1")],
)
def test_guards_run_before_any_network_call(args, message, capsys, monkeypatch):
    monkeypatch.setattr(upload, "Client", lambda *_: pytest.fail("contacted Google"))
    assert upload.main(args) == 1
    assert message in capsys.readouterr().err


def test_a_missing_bundle_asks_for_a_release_build(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(upload, "Client", lambda *_: pytest.fail("contacted Google"))
    assert upload.main(["--bundle", str(tmp_path / "none.aab")]) == 1
    assert "make android-release" in capsys.readouterr().err


def test_an_access_token_from_ci_skips_the_key_exchange():
    class NoNetwork:
        headers: dict = {}
        def post(self, *args, **kwargs):
            pytest.fail("exchanged a key in CI")
    client = upload.Client(access_token="ya29.ci-token", session=NoNetwork())
    assert client.session.headers["Authorization"] == "Bearer ya29.ci-token"


def test_no_credentials_at_all_is_named():
    with pytest.raises(upload.Failure, match="MAGPIE_PLAY_ACCESS_TOKEN"):
        upload.Client()


def test_the_callers_version_name_names_the_release(tmp_path):
    bundle = tmp_path / "app.aab"; bundle.write_bytes(b"aab")
    client = FakeClient()
    upload.publish(client, track="internal", bundle=bundle, mapping=None, notes=[], draft=True,
                   rollout=None, version_name="1.0.3", log=lambda _: None)
    assert client.track_body["releases"][0]["name"] == "3 (1.0.3)"
