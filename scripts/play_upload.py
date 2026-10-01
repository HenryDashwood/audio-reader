#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]>=2.8", "requests>=2.31"]
# ///
"""Upload Magpie's signed Android App Bundle to a Google Play track.

`make android-release` builds and signs the bundle and stops there. Everything
after that — the upload, the R8 mapping file, the release notes and the track —
is Google Play Developer API work, which is what this does, in one edit that is
committed only when every step has succeeded.

    make android-release
    make android-upload                  # internal testing, rolled out to testers
    make android-upload TRACK=alpha      # closed testing
    make android-upload DRAFT=1          # leave the release as a draft to review

Production needs `--confirm-production`; nothing here reaches the public by
default. Release notes come from `play-store/release_notes/<language>.txt`,
which is edited and committed before each upload.

In CI (.github/workflows/play-release.yml) workload identity federation supplies
a short-lived MAGPIE_PLAY_ACCESS_TOKEN and no key exists. Locally, credentials
are a Google Cloud service-account JSON key, never in the repository. The first
of these that is set is used:

  MAGPIE_PLAY_SERVICE_ACCOUNT_JSON   the key's contents (for CI)
  MAGPIE_PLAY_SERVICE_ACCOUNT        a path to the key file
  MAGPIE_PLAY_SERVICE_ACCOUNT=...    the same, in ~/.gradle/gradle.properties
  ~/.config/magpie/play-service-account.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections.abc import Mapping
from pathlib import Path

import jwt
import requests

PACKAGE = "com.henrydashwood.magpie"
API = f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PACKAGE}"
UPLOAD_API = f"https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/{PACKAGE}"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"

REPOSITORY = Path(__file__).resolve().parent.parent
BUNDLE = REPOSITORY / "android/app/build/outputs/bundle/release/app-release.aab"
MAPPING = REPOSITORY / "android/app/build/outputs/mapping/release/mapping.txt"
NOTES = REPOSITORY / "play-store/release_notes"
DEFAULT_KEY = Path.home() / ".config/magpie/play-service-account.json"
GRADLE_PROPERTIES = Path.home() / ".gradle/gradle.properties"

# Play's names: internal testing, closed testing ("alpha"), open testing ("beta").
TRACKS = ("internal", "alpha", "beta", "production")
NOTES_LIMIT = 500


class Failure(Exception):
    """Something went wrong that a human needs to look at."""


def service_account(environ: Mapping[str, str], properties: Path = GRADLE_PROPERTIES,
                    default: Path = DEFAULT_KEY) -> dict:
    """The service-account key, from the first place that has one."""
    if environ.get("MAGPIE_PLAY_SERVICE_ACCOUNT_JSON"):
        return _key(json.loads(environ["MAGPIE_PLAY_SERVICE_ACCOUNT_JSON"]), "MAGPIE_PLAY_SERVICE_ACCOUNT_JSON")
    path = environ.get("MAGPIE_PLAY_SERVICE_ACCOUNT") or _gradle_property(properties, "MAGPIE_PLAY_SERVICE_ACCOUNT")
    candidate = Path(path).expanduser() if path else default
    if not candidate.is_file():
        raise Failure(
            f"no Play service-account key at {candidate}. Set MAGPIE_PLAY_SERVICE_ACCOUNT to its path; "
            "see docs/android-release.md"
        )
    return _key(json.loads(candidate.read_text(encoding="utf-8")), str(candidate))


def _gradle_property(path: Path, name: str) -> str | None:
    if not path.is_file():
        return None
    for line in path.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        if key.strip() == name and value.strip():
            return value.strip()
    return None


def _key(data: dict, source: str) -> dict:
    missing = [name for name in ("client_email", "private_key") if not data.get(name)]
    if data.get("type") != "service_account" or missing:
        raise Failure(f"{source} is not a service-account key")
    return data


def assertion(key: Mapping[str, str], now: int) -> str:
    """A signed request for an access token, as Google's OAuth server expects."""
    claims = {"iss": key["client_email"], "scope": SCOPE, "aud": TOKEN_URL, "iat": now, "exp": now + 3600}
    headers = {"kid": key["private_key_id"]} if key.get("private_key_id") else None
    return jwt.encode(claims, key["private_key"], algorithm="RS256", headers=headers)


def release_notes(directory: Path = NOTES) -> list[dict]:
    """Every language's notes, each within Play's limit."""
    notes = []
    for path in sorted(directory.glob("*.txt")):
        text = path.read_text(encoding="utf-8").strip()
        if not text:
            raise Failure(f"{path} is empty")
        if len(text) > NOTES_LIMIT:
            raise Failure(f"{path} is {len(text)} characters; Play allows {NOTES_LIMIT}")
        notes.append({"language": path.stem, "text": text})
    if not notes:
        raise Failure(f"no release notes in {directory}")
    return notes


def release(version_code: int, version_name: str | None, notes: list[dict], *, draft: bool,
            rollout: float | None) -> dict:
    """The track release body for one uploaded bundle."""
    body: dict = {
        "name": f"{version_code} ({version_name})" if version_name else str(version_code),
        "versionCodes": [str(version_code)],
        "releaseNotes": notes,
    }
    if draft:
        body["status"] = "draft"
    elif rollout is not None:
        body["status"] = "inProgress"
        body["userFraction"] = rollout
    else:
        body["status"] = "completed"
    return body


class Client:
    def __init__(self, key: dict | None = None, session: requests.Session | None = None, *,
                 access_token: str | None = None) -> None:
        self.session = session or requests.Session()
        if access_token:
            # CI: a short-lived token from workload identity federation; no key exists.
            self.session.headers["Authorization"] = f"Bearer {access_token}"
            return
        if key is None:
            raise Failure("no Play credentials: set MAGPIE_PLAY_ACCESS_TOKEN or a service-account key")
        response = self.session.post(TOKEN_URL, timeout=60, data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion(key, int(time.time())),
        })
        if not response.ok:
            raise Failure(f"Google refused the service-account key: {response.status_code}: {response.text}")
        self.session.headers["Authorization"] = f"Bearer {response.json()['access_token']}"

    def request(self, method: str, url: str, **kwargs) -> dict:
        response = self.session.request(method, url, timeout=600, **kwargs)
        if not response.ok:
            # Google's errors carry the useful detail in the body, not the status.
            raise Failure(f"{method} {url.split(PACKAGE, 1)[-1]} -> {response.status_code}: {response.text}")
        return response.json() if response.content else {}

    def upload(self, url: str, path: Path) -> dict:
        with path.open("rb") as handle:
            return self.request("POST", url, params={"uploadType": "media"}, data=handle,
                                headers={"Content-Type": "application/octet-stream"})


def publish(client: Client, *, track: str, bundle: Path, mapping: Path | None, notes: list[dict],
            draft: bool, rollout: float | None, log=print) -> int:
    """Upload, attach, assign and commit in one edit; abandon the edit on any failure."""
    edit = client.request("POST", f"{API}/edits")["id"]
    try:
        log(f"Uploading {bundle.name} ({bundle.stat().st_size / 1_000_000:.1f} MB)…")
        uploaded = client.upload(f"{UPLOAD_API}/edits/{edit}/bundles", bundle)
        version_code = int(uploaded["versionCode"])
        if mapping is not None:
            log(f"Attaching the R8 mapping file for version code {version_code}…")
            client.upload(f"{UPLOAD_API}/edits/{edit}/apks/{version_code}/deobfuscationFiles/proguard", mapping)
        name = _version_name(client, edit, version_code)
        body = release(version_code, name, notes, draft=draft, rollout=rollout)
        client.request("PUT", f"{API}/edits/{edit}/tracks/{track}", json={"track": track, "releases": [body]})
        client.request("POST", f"{API}/edits/{edit}:commit")
    except BaseException as error:
        # An uncommitted edit blocks nothing, but leaving one around confuses the next run.
        try:
            client.request("DELETE", f"{API}/edits/{edit}")
        except Failure:
            pass
        if isinstance(error, Failure) and "draft app" in str(error).lower():
            raise Failure(f"{error}\nPlay accepts only draft releases until the app's first review; "
                          "rerun with DRAFT=1 and roll it out in Play Console.") from error
        raise
    log(f"Version code {version_code} is on the {track} track ({body['status']}).")
    return version_code


def _version_name(client: Client, edit: str, version_code: int) -> str | None:
    """The bundle's versionName, which Play reports only through the edit's APK list."""
    try:
        for apk in client.request("GET", f"{API}/edits/{edit}/apks").get("apks", []):
            if int(apk.get("versionCode", -1)) == version_code:
                return apk.get("binary", {}).get("versionName")
    except Failure:
        pass
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--track", choices=TRACKS, default="internal")
    parser.add_argument("--draft", action="store_true", help="create the release as a draft to review in Play Console")
    parser.add_argument("--rollout", type=float, help="production staged rollout fraction, e.g. 0.2")
    parser.add_argument("--confirm-production", action="store_true", help="required for --track production")
    parser.add_argument("--bundle", type=Path, default=BUNDLE)
    parser.add_argument("--mapping", type=Path, default=MAPPING)
    args = parser.parse_args(argv)
    try:
        if args.track == "production" and not args.confirm_production:
            raise Failure("production releases reach the public; pass --confirm-production to mean it")
        if args.rollout is not None and (args.track != "production" or not 0 < args.rollout < 1):
            raise Failure("--rollout is a fraction between 0 and 1, and only for production")
        if not args.bundle.is_file():
            raise Failure(f"no bundle at {args.bundle}; run make android-release first")
        mapping = args.mapping if args.mapping.is_file() else None
        if mapping is None:
            print(f"warning: no R8 mapping file at {args.mapping}; crash reports will be obfuscated", file=sys.stderr)
        notes = release_notes()
        token = os.environ.get("MAGPIE_PLAY_ACCESS_TOKEN")
        client = Client(access_token=token) if token else Client(service_account(os.environ))
        publish(client, track=args.track, bundle=args.bundle, mapping=mapping, notes=notes,
                draft=args.draft, rollout=args.rollout)
    except Failure as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
