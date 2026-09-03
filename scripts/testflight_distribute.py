#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]>=2.8", "requests>=2.31"]
# ///
"""Attach release notes to a TestFlight build and hand it to external testers.

`xcodebuild -exportArchive` uploads a build and stops there. Everything after
that — the What to Test text, the external group, the beta review submission —
is App Store Connect API work, which is what this does.

    ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_P8_BASE64=... \
      scripts/testflight_distribute.py --build-number 55 \
        --changelog docs/CHANGELOG.md --external-group "Friends and Family"

Without --external-group the notes are set and nothing is distributed, which is
what an untagged build wants.
"""

from __future__ import annotations

import argparse
import base64
import os
import re
import sys
import time
from collections.abc import Mapping

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.henrydashwood.hearful"

# Processing usually takes a few minutes; the ceiling is for the days it does not.
POLL_INTERVAL_SECONDS = 30
POLL_TIMEOUT_SECONDS = 30 * 60


class Failure(Exception):
    """Something went wrong that a human needs to look at."""


def token_claims(environ: Mapping[str, str], now: int) -> tuple[dict, str, str]:
    """The JWT payload, key id and private key for signing requests.

    An individual key is preferred when one is configured: the beta review
    submission it makes shows in App Store Connect under the person's name
    rather than as "API user <key id>". Individual keys carry `sub: user`
    and no issuer; the team key is the fallback.
    """
    # Apple rejects tokens with a lifetime over 20 minutes.
    claims: dict = {"iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
    if environ.get("ASC_INDIVIDUAL_KEY_ID") and environ.get("ASC_INDIVIDUAL_KEY_P8_BASE64"):
        claims["sub"] = "user"
        key = base64.b64decode(environ["ASC_INDIVIDUAL_KEY_P8_BASE64"]).decode()
        return claims, environ["ASC_INDIVIDUAL_KEY_ID"], key
    for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8_BASE64"):
        if not environ.get(name):
            raise Failure(f"{name} is not set")
    claims["iss"] = environ["ASC_ISSUER_ID"]
    return claims, environ["ASC_KEY_ID"], base64.b64decode(environ["ASC_KEY_P8_BASE64"]).decode()


def token() -> str:
    claims, key_id, key = token_claims(os.environ, int(time.time()))
    return jwt.encode(claims, key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


class Client:
    def __init__(self) -> None:
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {token()}"

    def request(self, method: str, path: str, **kwargs) -> dict:
        response = self.session.request(method, f"{API}{path}", timeout=60, **kwargs)
        if not response.ok:
            # Apple's errors carry the useful detail in the body, not the status.
            raise Failure(f"{method} {path} -> {response.status_code}: {response.text}")
        return response.json() if response.content else {}

    def get(self, path: str, **kwargs) -> dict:
        return self.request("GET", path, **kwargs)

    def post(self, path: str, body: dict) -> dict:
        return self.request("POST", path, json=body)

    def patch(self, path: str, body: dict) -> dict:
        return self.request("PATCH", path, json=body)


def latest_changelog_entry(path: str) -> tuple[str, str]:
    """Return (version, notes) from the topmost `## ` section."""
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    sections = re.split(r"^## +(.+?) *$", text, flags=re.MULTILINE)
    if len(sections) < 3:
        raise Failure(f"{path} has no '## <version>' section")

    version, body = sections[1].strip(), sections[2].strip()
    if not body:
        raise Failure(f"the '## {version}' section in {path} is empty")
    return version, body


def app_id(client: Client) -> str:
    data = client.get("/apps", params={"filter[bundleId]": BUNDLE_ID})["data"]
    if not data:
        raise Failure(f"no app found for bundle id {BUNDLE_ID}")
    return data[0]["id"]


def wait_for_build(client: Client, app: str, build_number: str) -> str:
    """Block until the build finishes processing, and return its id."""
    deadline = time.time() + POLL_TIMEOUT_SECONDS
    reported = None

    while True:
        data = client.get(
            "/builds",
            params={"filter[app]": app, "filter[version]": build_number},
        )["data"]

        if data:
            build = data[0]
            state = build["attributes"]["processingState"]
            if state != reported:
                print(f"build {build_number}: {state}", flush=True)
                reported = state
            if state == "VALID":
                return build["id"]
            if state in ("FAILED", "INVALID"):
                raise Failure(f"build {build_number} finished processing as {state}")
        elif reported is None:
            # The build can take a minute to appear at all after upload.
            print(f"build {build_number}: not visible yet", flush=True)
            reported = "absent"

        if time.time() > deadline:
            raise Failure(
                f"build {build_number} was still {reported or 'absent'} after {POLL_TIMEOUT_SECONDS // 60} minutes"
            )
        time.sleep(POLL_INTERVAL_SECONDS)


def set_release_notes(client: Client, build: str, notes: str) -> None:
    """Set What to Test on every locale the build already has, or create one."""
    existing = client.get(f"/builds/{build}/betaBuildLocalizations")["data"]

    if existing:
        for localization in existing:
            client.patch(
                f"/betaBuildLocalizations/{localization['id']}",
                {
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": localization["id"],
                        "attributes": {"whatsNew": notes},
                    }
                },
            )
        locales = ", ".join(item["attributes"]["locale"] for item in existing)
        print(f"set release notes for {locales}", flush=True)
        return

    client.post(
        "/betaBuildLocalizations",
        {
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": "en-GB", "whatsNew": notes},
                "relationships": {"build": {"data": {"type": "builds", "id": build}}},
            }
        },
    )
    print("set release notes for en-GB", flush=True)


def distribute(client: Client, app: str, build: str, group_name: str) -> None:
    groups = client.get("/betaGroups", params={"filter[app]": app})["data"]
    match = next((g for g in groups if g["attributes"]["name"] == group_name), None)
    if match is None:
        available = ", ".join(repr(g["attributes"]["name"]) for g in groups)
        raise Failure(f"no beta group named {group_name!r}; found: {available}")

    client.post(
        f"/betaGroups/{match['id']}/relationships/builds",
        {"data": [{"type": "builds", "id": build}]},
    )
    print(f"added build to {group_name!r}", flush=True)

    if not match["attributes"].get("isInternalGroup", False):
        submit_for_review(client, build)


def submit_for_review(client: Client, build: str) -> None:
    try:
        client.post(
            "/betaAppReviewSubmissions",
            {
                "data": {
                    "type": "betaAppReviewSubmissions",
                    "relationships": {"build": {"data": {"type": "builds", "id": build}}},
                }
            },
        )
        print("submitted for beta app review", flush=True)
    except Failure as error:
        # Adding a build to an external group can submit it as a side effect,
        # and Apple then rejects the explicit submission as a duplicate.
        if "409" in str(error):
            print("already submitted for beta app review", flush=True)
            return
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--changelog", default="docs/CHANGELOG.md")
    parser.add_argument(
        "--expect-version",
        help="fail unless the changelog's top section is this version",
    )
    parser.add_argument(
        "--external-group",
        help="beta group to distribute to; omitted means notes only",
    )
    args = parser.parse_args()

    try:
        version, notes = latest_changelog_entry(args.changelog)
        if args.expect_version and version != args.expect_version:
            raise Failure(
                f"releasing {args.expect_version} but {args.changelog} has "
                f"'## {version}' at the top — add the new section before tagging"
            )
        print(f"notes from '## {version}' ({len(notes)} chars)", flush=True)

        client = Client()
        app = app_id(client)
        build = wait_for_build(client, app, args.build_number)
        set_release_notes(client, build, notes)

        if args.external_group:
            distribute(client, app, build, args.external_group)
        else:
            print("no external group requested; build stays internal", flush=True)
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
