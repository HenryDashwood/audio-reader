from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app_store_sync as store


def listing(*, description: str = "Description") -> store.Listing:
    fields = {
        "name": "Hearful",
        "subtitle": "Podcasts and articles by voice",
        "description": description,
        "keywords": "podcast,voice",
        "promotional_text": "Ask for something worth hearing.",
        "support_url": "https://example.com/support",
        "privacy_policy_url": "https://example.com/privacy",
    }
    return store.Listing(
        config={
            "bundleId": "com.example.hearful",
            "platform": "IOS",
            "primaryLocale": "en-GB",
            "copyright": "2026 Example",
            "releaseType": "MANUAL",
        },
        locales=(store.LocaleListing("en-GB", fields, {}),),
        review_notes="Review these steps.",
    )


def test_empty_screenshot_directories_are_safe_but_visible():
    warnings = store.validate_listing(listing())
    assert warnings == ["en-GB has no screenshots yet; remote screenshot sets will be left alone"]


def test_metadata_over_apples_limit_is_rejected():
    with pytest.raises(store.Failure, match="4001 characters"):
        store.validate_listing(listing(description="x" * 4_001))


class FakeScreenshotClient:
    def __init__(self, filename: str, checksum: str):
        self.filename = filename
        self.checksum = checksum
        self.deleted: list[str] = []
        self.patched: list[str] = []

    def get(self, path: str, **_kwargs) -> dict:
        if path.endswith("/appScreenshotSets"):
            return {
                "data": [
                    {
                        "id": "set-id",
                        "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
                    }
                ]
            }
        if path.endswith("/appScreenshots"):
            return {
                "data": [
                    {
                        "id": "image-id",
                        "attributes": {
                            "fileName": self.filename,
                            "sourceFileChecksum": self.checksum,
                        },
                    }
                ]
            }
        raise AssertionError(path)

    def delete(self, path: str) -> None:
        self.deleted.append(path)

    def patch(self, path: str, _body: dict) -> dict:
        self.patched.append(path)
        return {}


def test_matching_screenshot_set_is_not_replaced(tmp_path: Path):
    screenshot = tmp_path / "01-latest.png"
    screenshot.write_bytes(b"approved image")
    checksum = hashlib.md5(screenshot.read_bytes()).hexdigest()
    client = FakeScreenshotClient(screenshot.name, checksum)
    locale = store.LocaleListing("en-GB", {}, {"APP_IPHONE_67": (screenshot,)})

    store.sync_screenshots(client, {"id": "localization-id"}, locale, dry_run=False)

    assert client.deleted == []
    assert client.patched == []


def test_dry_run_never_replaces_changed_screenshot_set(tmp_path: Path):
    screenshot = tmp_path / "01-latest.png"
    screenshot.write_bytes(b"new image")
    client = FakeScreenshotClient(screenshot.name, "old-checksum")
    locale = store.LocaleListing("en-GB", {}, {"APP_IPHONE_67": (screenshot,)})

    store.sync_screenshots(client, {"id": "localization-id"}, locale, dry_run=True)

    assert client.deleted == []
    assert client.patched == []


class FakeVersionClient:
    def __init__(self, *, build: dict | None = None):
        self.versions = [
            {
                "id": "draft-id",
                "attributes": {
                    "versionString": "1.0",
                    "appStoreState": "PREPARE_FOR_SUBMISSION",
                    "copyright": "2025 Example",
                    "releaseType": "MANUAL",
                },
            }
        ]
        self.build = build
        self.patches: list[tuple[str, dict]] = []

    def get(self, path: str, **_kwargs) -> dict:
        if path.endswith("/appStoreVersions"):
            return {"data": self.versions}
        if path.endswith("/build"):
            return {"data": self.build}
        raise AssertionError(path)

    def patch(self, path: str, body: dict) -> dict:
        self.patches.append((path, body))
        return {"data": self.versions[0]}


def test_empty_editable_version_is_retargeted_for_release():
    client = FakeVersionClient()

    result = store.ensure_version(client, "app-id", listing(), "1.3.0", dry_run=False)

    assert result is not None
    assert result["id"] == "draft-id"
    assert result["attributes"]["versionString"] == "1.3.0"
    assert client.patches[0][0] == "/appStoreVersions/draft-id"
    assert client.patches[0][1]["data"]["attributes"]["versionString"] == "1.3.0"


def test_dry_run_plans_retarget_without_writing():
    client = FakeVersionClient()

    result = store.ensure_version(client, "app-id", listing(), "1.3.0", dry_run=True)

    assert result is not None
    assert result["attributes"]["versionString"] == "1.3.0"
    assert client.patches == []


def test_version_with_selected_build_is_not_retargeted():
    client = FakeVersionClient(build={"id": "build-id", "type": "builds"})

    with pytest.raises(store.Failure, match="already has a selected build"):
        store.ensure_version(client, "app-id", listing(), "1.3.0", dry_run=False)

    assert client.patches == []


def test_a_rejected_draft_with_a_build_is_retargeted_when_the_build_will_be_replaced():
    client = FakeVersionClient(build={"id": "build-133", "type": "builds"})
    client.versions[0]["attributes"]["appStoreState"] = "DEVELOPER_REJECTED"

    result = store.ensure_version(client, "app-id", listing(), "1.4.1", dry_run=False, build_number="180")

    assert result is not None and result["attributes"]["versionString"] == "1.4.1"
    assert client.patches[0][1]["data"]["attributes"]["versionString"] == "1.4.1"


class FakeBuildClient:
    def __init__(self, *, current: dict | None, builds: list[dict]):
        self.current = current
        self.builds = builds
        self.patches: list[tuple[str, dict]] = []

    def get(self, path: str, **kwargs) -> dict:
        if path == "/builds":
            assert kwargs["params"]["filter[preReleaseVersion.version]"] == "1.4.1"
            return {"data": self.builds}
        if path.endswith("/build"):
            return {"data": self.current}
        raise AssertionError(path)

    def patch(self, path: str, body: dict) -> dict:
        self.patches.append((path, body))
        return {}


def version_1_4_1() -> dict:
    return {"id": "v-id", "attributes": {"versionString": "1.4.1", "appStoreState": "PREPARE_FOR_SUBMISSION"}}


def test_the_processed_build_for_the_version_replaces_the_old_one():
    processed = {"id": "b180", "attributes": {"version": "180", "processingState": "VALID"}}
    client = FakeBuildClient(current={"id": "b133", "attributes": {"version": "133"}}, builds=[processed])

    store.select_build(client, "app-id", version_1_4_1(), "180", dry_run=False)

    assert client.patches == [
        ("/appStoreVersions/v-id/relationships/build", {"data": {"type": "builds", "id": "b180"}})
    ]


def test_a_build_still_processing_cannot_be_selected():
    client = FakeBuildClient(current=None, builds=[{"id": "b180", "attributes": {"processingState": "PROCESSING"}}])

    with pytest.raises(store.Failure, match="no processed build 180 carries version 1.4.1"):
        store.select_build(client, "app-id", version_1_4_1(), "180", dry_run=False)


def test_an_already_selected_build_is_left_alone():
    processed = {"id": "b180", "attributes": {"version": "180", "processingState": "VALID"}}
    client = FakeBuildClient(current={"id": "b180", "attributes": {"version": "180"}}, builds=[processed])

    store.select_build(client, "app-id", version_1_4_1(), "180", dry_run=False)

    assert client.patches == []


class FakeSubmissionClient:
    def __init__(self, submissions: list[dict], items: list[dict] | None = None):
        self.submissions = submissions
        self.items = items or []
        self.posts: list[tuple[str, dict]] = []
        self.patches: list[tuple[str, dict]] = []

    def get(self, path: str, **_kwargs) -> dict:
        if path == "/reviewSubmissions":
            return {"data": self.submissions}
        if path.endswith("/items"):
            return {"data": self.items}
        raise AssertionError(path)

    def post(self, path: str, body: dict) -> dict:
        self.posts.append((path, body))
        return {"data": {"id": "new-submission"}}

    def patch(self, path: str, body: dict) -> dict:
        self.patches.append((path, body))
        return {}


def test_a_submission_apple_holds_is_reported_not_repeated(capsys):
    client = FakeSubmissionClient([{"id": "s1", "attributes": {"state": "WAITING_FOR_REVIEW"}}])

    store.submit_for_review(client, "app-id", version_1_4_1(), "IOS", dry_run=False)

    assert client.posts == [] and client.patches == []
    assert "already WAITING_FOR_REVIEW" in capsys.readouterr().out


def test_a_fresh_submission_holds_the_version_and_is_submitted():
    client = FakeSubmissionClient([{"id": "old", "attributes": {"state": "COMPLETE"}}])

    store.submit_for_review(client, "app-id", version_1_4_1(), "IOS", dry_run=False)

    assert [path for path, _ in client.posts] == ["/reviewSubmissions", "/reviewSubmissionItems"]
    item = client.posts[1][1]["data"]["relationships"]
    assert item["reviewSubmission"]["data"]["id"] == "new-submission"
    assert item["appStoreVersion"]["data"]["id"] == "v-id"
    assert client.patches == [
        (
            "/reviewSubmissions/new-submission",
            {"data": {"type": "reviewSubmissions", "id": "new-submission", "attributes": {"submitted": True}}},
        )
    ]


def test_a_draft_submission_already_holding_the_version_is_just_submitted():
    draft = {"id": "draft", "attributes": {"state": "READY_FOR_REVIEW"}}
    held = {"relationships": {"appStoreVersion": {"data": {"id": "v-id"}}}}
    client = FakeSubmissionClient([draft], items=[held])

    store.submit_for_review(client, "app-id", version_1_4_1(), "IOS", dry_run=False)

    assert client.posts == []
    assert client.patches[0][0] == "/reviewSubmissions/draft"


def test_dry_run_submits_nothing():
    client = FakeSubmissionClient([])

    store.submit_for_review(client, "app-id", version_1_4_1(), "IOS", dry_run=True)

    assert client.posts == [] and client.patches == []


class FakeInFlightVersionClient(FakeVersionClient):
    """The app has 1.3.0 waiting for review and nothing editable, and Apple
    answers the attempt to create 1.4.0 with its unhelpful 409."""

    def __init__(self):
        super().__init__()
        self.versions = [
            {"id": "old-id", "attributes": {"versionString": "1.2.0", "appStoreState": "REPLACED_WITH_NEW_VERSION"}},
            {"id": "live-id", "attributes": {"versionString": "1.3.0", "appStoreState": "WAITING_FOR_REVIEW"}},
        ]

    def post(self, path: str, body: dict) -> dict:
        raise store.AppStoreConnectFailure(
            "POST",
            path,
            409,
            json.dumps(
                {
                    "errors": [
                        {
                            "status": "409",
                            "code": "ENTITY_ERROR.RELATIONSHIP.INVALID",
                            "detail": "You cannot create a new version of the App in the current state.",
                        }
                    ]
                }
            ),
        )


def test_refused_version_creation_names_the_version_in_flight():
    client = FakeInFlightVersionClient()

    with pytest.raises(store.Failure) as failure:
        store.ensure_version(client, "app-id", listing(), "1.4.0", dry_run=False)

    message = str(failure.value)
    assert "1.3.0 (WAITING_FOR_REVIEW)" in message
    assert "1.2.0" not in message
    assert "sync_version=1.4.0" in message


class FakeResponse:
    def __init__(self, status_code: int, body: dict | None = None):
        self.status_code = status_code
        self.ok = status_code < 400
        self.content = json.dumps(body).encode() if body is not None else b""
        self.text = self.content.decode()

    def json(self) -> dict:
        return json.loads(self.text)


class FakeSession:
    def __init__(self, responses: list[FakeResponse]):
        self.responses = list(responses)
        self.headers: dict[str, str] = {}
        self.calls: list[tuple[str, str, str]] = []

    def request(self, method: str, url: str, **_kwargs) -> FakeResponse:
        self.calls.append((method, url, self.headers["Authorization"]))
        return self.responses.pop(0)


def retrying_client(monkeypatch, responses: list[FakeResponse]) -> tuple[store.Client, FakeSession, list[float]]:
    tokens = iter(("first", "second", "third"))
    monkeypatch.setattr(store, "api_token", lambda: next(tokens))
    slept: list[float] = []
    session = FakeSession(responses)
    return store.Client(session, sleep=slept.append), session, slept


def test_a_passing_401_is_retried_with_a_fresh_token(monkeypatch):
    client, session, slept = retrying_client(monkeypatch, [FakeResponse(401), FakeResponse(200, {"data": []})])

    assert client.get("/apps") == {"data": []}
    assert [call[2] for call in session.calls] == ["Bearer first", "Bearer second"]
    assert slept == [store.RETRY_DELAY_SECONDS]


def test_a_persistent_failure_is_reported_after_the_last_attempt(monkeypatch):
    client, session, _ = retrying_client(monkeypatch, [FakeResponse(503)] * store.RETRY_ATTEMPTS)

    with pytest.raises(store.AppStoreConnectFailure, match="-> 503"):
        client.get("/apps")
    assert len(session.calls) == store.RETRY_ATTEMPTS


def test_a_post_that_may_have_landed_is_not_retried(monkeypatch):
    client, session, slept = retrying_client(monkeypatch, [FakeResponse(503), FakeResponse(201, {"data": {}})])

    with pytest.raises(store.AppStoreConnectFailure, match="-> 503"):
        client.post("/appStoreVersions", {})
    assert len(session.calls) == 1
    assert slept == []


class FakeFirstVersionLocalizationClient:
    def __init__(self):
        self.patches: list[dict] = []

    def get(self, path: str, **_kwargs) -> dict:
        if path.endswith("/appStoreVersionLocalizations"):
            return {
                "data": [
                    {
                        "id": "localization-id",
                        "attributes": {"locale": "en-GB"},
                    }
                ]
            }
        raise AssertionError(path)

    def patch(self, _path: str, body: dict) -> dict:
        attributes = body["data"]["attributes"]
        self.patches.append(attributes)
        if "whatsNew" in attributes:
            response = {
                "errors": [
                    {
                        "code": "STATE_ERROR",
                        "detail": "Attribute 'whatsNew' cannot be edited at this time",
                    }
                ]
            }
            raise store.AppStoreConnectFailure("PATCH", "/localization", 409, json.dumps(response))
        return {}


def test_first_public_version_syncs_without_unavailable_whats_new():
    client = FakeFirstVersionLocalizationClient()

    store.sync_version_localizations(
        client,
        {"id": "version-id"},
        listing(),
        "Release notes",
        dry_run=False,
    )

    assert client.patches[0]["whatsNew"] == "Release notes"
    assert "whatsNew" not in client.patches[1]
    assert client.patches[1]["description"] == "Description"


def test_team_key_signs_with_an_issuer():
    key = store.signing_key({"ASC_KEY_ID": "TEAMKEY", "ASC_ISSUER_ID": "issuer-uuid", "ASC_KEY_P8_BASE64": "a2V5"})

    assert key.key_id == "TEAMKEY"
    assert key.private_key == "key"
    claims = key.claims(1_000)
    assert claims["iss"] == "issuer-uuid"
    assert "sub" not in claims
    assert claims["exp"] - claims["iat"] == 19 * 60
    assert claims["aud"] == "appstoreconnect-v1"


def test_an_individual_key_is_preferred_and_signs_as_the_person():
    key = store.signing_key(
        {
            "ASC_KEY_ID": "TEAMKEY",
            "ASC_ISSUER_ID": "issuer-uuid",
            "ASC_KEY_P8_BASE64": "a2V5",
            "ASC_INDIVIDUAL_KEY_ID": "MYKEY",
            "ASC_INDIVIDUAL_KEY_P8_BASE64": "bWluZQ==",
        }
    )

    assert key.key_id == "MYKEY"
    assert key.private_key == "mine"
    claims = key.claims(1_000)
    assert claims["sub"] == "user"
    assert "iss" not in claims


def test_a_half_configured_individual_key_falls_back_to_the_team_key():
    key = store.signing_key(
        {
            "ASC_KEY_ID": "TEAMKEY",
            "ASC_ISSUER_ID": "issuer-uuid",
            "ASC_KEY_P8_BASE64": "a2V5",
            "ASC_INDIVIDUAL_KEY_ID": "MYKEY",
        }
    )

    assert key.key_id == "TEAMKEY"


def test_missing_team_key_is_named():
    with pytest.raises(store.Failure, match="ASC_ISSUER_ID is not set"):
        store.signing_key({"ASC_KEY_ID": "TEAMKEY", "ASC_KEY_P8_BASE64": "a2V5"})


def test_beta_description_is_optional_but_bounded(tmp_path: Path):
    root = tmp_path / "app-store"
    locale = root / "metadata" / "en-GB"
    locale.mkdir(parents=True)
    (root / "config.json").write_text(
        json.dumps(
            {
                "bundleId": "com.example.hearful",
                "platform": "IOS",
                "primaryLocale": "en-GB",
                "copyright": "2026 Example",
                "releaseType": "MANUAL",
            }
        )
    )
    for field in store.REQUIRED_FIELDS:
        value = "https://example.com/page" if field.endswith("_url") else "Words"
        (locale / f"{field}.txt").write_text(value)
    (root / "review_notes.txt").write_text("Review these steps.")

    assert "beta_description" not in store.load_listing(root).locales[0].fields

    (locale / "beta_description.txt").write_text("What testers read.")
    assert store.load_listing(root).locales[0].fields["beta_description"] == "What testers read."

    (locale / "beta_description.txt").write_text("x" * 4_001)
    with pytest.raises(store.Failure, match="beta_description is 4001 characters"):
        store.validate_listing(store.load_listing(root))


def beta_listing(description: str = "What testers read.") -> store.Listing:
    base = listing()
    locale = base.locales[0]
    return store.Listing(
        config=base.config,
        locales=(store.LocaleListing(locale.locale, {**locale.fields, "beta_description": description}, {}),),
        review_notes=base.review_notes,
    )


class FakeTestFlightClient:
    def __init__(self, *, localizations: list[dict] | None = None, review: dict | None = None):
        self.localizations = localizations or []
        self.review = review
        self.posts: list[tuple[str, dict]] = []
        self.patches: list[tuple[str, dict]] = []

    def get(self, path: str, **_kwargs) -> dict:
        if path.endswith("/betaAppLocalizations"):
            return {"data": self.localizations}
        if path.endswith("/betaAppReviewDetail"):
            return {"data": self.review}
        raise AssertionError(path)

    def post(self, path: str, body: dict) -> dict:
        self.posts.append((path, body))
        return {"data": {}}

    def patch(self, path: str, body: dict) -> dict:
        self.patches.append((path, body))
        return {"data": {}}


def test_beta_description_is_created_for_a_new_locale():
    client = FakeTestFlightClient()

    store.sync_beta_descriptions(client, "app-id", beta_listing(), dry_run=False)

    assert client.posts[0][0] == "/betaAppLocalizations"
    attributes = client.posts[0][1]["data"]["attributes"]
    assert attributes == {"description": "What testers read.", "locale": "en-GB"}
    assert client.posts[0][1]["data"]["relationships"]["app"]["data"]["id"] == "app-id"


def test_beta_description_is_updated_only_when_it_differs():
    remote = {"id": "loc-id", "attributes": {"locale": "en-GB", "description": "Old words."}}
    client = FakeTestFlightClient(localizations=[remote])

    store.sync_beta_descriptions(client, "app-id", beta_listing("Old words."), dry_run=False)
    assert client.patches == []

    store.sync_beta_descriptions(client, "app-id", beta_listing(), dry_run=False)
    assert client.patches[0][0] == "/betaAppLocalizations/loc-id"
    assert client.patches[0][1]["data"]["attributes"] == {"description": "What testers read."}


def test_no_beta_description_leaves_testflight_alone():
    client = FakeTestFlightClient()

    store.sync_beta_descriptions(client, "app-id", listing(), dry_run=False)

    assert client.posts == [] and client.patches == []


def test_beta_review_details_carry_the_contact_and_notes(monkeypatch):
    for name, value in (
        ("ASC_REVIEW_CONTACT_FIRST_NAME", "Ada"),
        ("ASC_REVIEW_CONTACT_LAST_NAME", "Lovelace"),
        ("ASC_REVIEW_CONTACT_EMAIL", "ada@example.com"),
        ("ASC_REVIEW_CONTACT_PHONE", "+44 20 7946 0000"),
    ):
        monkeypatch.setenv(name, value)
    client = FakeTestFlightClient(review={"id": "review-id", "attributes": {"notes": "Stale."}})

    store.sync_beta_review_details(client, "app-id", listing(), dry_run=False)

    assert client.patches[0][0] == "/betaAppReviewDetails/review-id"
    attributes = client.patches[0][1]["data"]["attributes"]
    assert attributes["notes"] == "Review these steps."
    assert attributes["contactLastName"] == "Lovelace"
    assert attributes["demoAccountRequired"] is False


def test_beta_review_details_need_every_contact_field(monkeypatch):
    monkeypatch.delenv("ASC_REVIEW_CONTACT_PHONE", raising=False)
    monkeypatch.setenv("ASC_REVIEW_CONTACT_FIRST_NAME", "Ada")

    with pytest.raises(store.Failure, match="ASC_REVIEW_CONTACT_PHONE"):
        store.sync_beta_review_details(FakeTestFlightClient(), "app-id", listing(), dry_run=False)


class FakeStatusClient:
    def get(self, path: str, **kwargs) -> dict:
        if path.endswith("/appStoreVersions"):
            return {
                "data": [
                    {"id": "v13", "attributes": {"versionString": "1.3.0", "appStoreState": "WAITING_FOR_REVIEW"}},
                    {
                        "id": "v12",
                        "attributes": {"versionString": "1.2.0", "appStoreState": "REPLACED_WITH_NEW_VERSION"},
                    },
                ]
            }
        if path == "/appStoreVersions/v13/build":
            return {"data": {"attributes": {"version": "160"}}}
        if path == "/reviewSubmissions":
            return {"data": [{"attributes": {"submittedDate": "2026-08-30T10:14:00Z", "state": "CANCELING"}}]}
        if path == "/builds":
            return {
                "data": [
                    {
                        "id": "b174",
                        "attributes": {"version": "174", "processingState": "VALID", "expired": False},
                        "relationships": {"preReleaseVersion": {"data": {"id": "pre14"}}},
                    }
                ],
                "included": [{"id": "pre14", "type": "preReleaseVersions", "attributes": {"version": "1.4.0"}}],
            }
        if path == "/builds/b174/betaAppReviewSubmission":
            return {"data": {"attributes": {"betaReviewState": "WAITING_FOR_REVIEW"}}}
        if path == "/betaGroups":
            return {
                "data": [
                    {
                        "id": "g1",
                        "attributes": {"name": "Team", "isInternalGroup": True, "hasAccessToAllBuilds": True},
                    },
                    {
                        "id": "g2",
                        "attributes": {
                            "name": "Friends and Family",
                            "isInternalGroup": False,
                            "hasAccessToAllBuilds": False,
                        },
                    },
                ]
            }
        if path == "/betaGroups/g1/betaTesters":
            return {"data": [], "meta": {"paging": {"total": 1}}}
        if path == "/betaGroups/g2/betaTesters":
            return {"data": [], "meta": {"paging": {"total": 4}}}
        if path == "/betaGroups/g2/builds":
            return {"data": [{"attributes": {"version": "174"}}, {"attributes": {"version": "133"}}]}
        raise AssertionError(path)


def test_status_reports_versions_submissions_and_builds_as_the_api_sees_them():
    lines = store.status_report(FakeStatusClient(), "app-id", "IOS")

    assert lines == [
        "App Store versions:",
        "  1.3.0: WAITING_FOR_REVIEW, build 160",
        "  1.2.0: REPLACED_WITH_NEW_VERSION",
        "Review submissions:",
        "  2026-08-30T10:14:00Z: CANCELING",
        "Recent builds:",
        "  1.4.0 (174): VALID, beta review WAITING_FOR_REVIEW",
        "Beta groups:",
        "  Team (internal, 1 testers): every build automatically",
        "  Friends and Family (external, 4 testers): builds 174, 133",
    ]
