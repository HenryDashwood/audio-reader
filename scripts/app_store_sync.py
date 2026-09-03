#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]>=2.8", "requests>=2.31"]
# ///
"""Validate and synchronise Magpie's version-controlled App Store listing.

Validation is offline and works with the system Python. The ``sync`` command
uses the same App Store Connect API-key environment variables as the existing
TestFlight release script and never submits or releases a version.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import struct
import sys
import time
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

API = "https://api.appstoreconnect.apple.com/v1"
REPOSITORY = Path(__file__).resolve().parent.parent
STORE_ROOT = REPOSITORY / "app-store"

FIELD_LIMITS = {
    "name": 30,
    "subtitle": 30,
    "description": 4_000,
    "keywords": 100,
    "promotional_text": 170,
    "review_notes": 4_000,
    "whats_new": 4_000,
    "beta_description": 4_000,
}
REQUIRED_FIELDS = (
    "name",
    "subtitle",
    "description",
    "keywords",
    "promotional_text",
    "support_url",
    "privacy_policy_url",
)
APP_INFO_FIELDS = {
    "name": "name",
    "subtitle": "subtitle",
    "privacy_policy_url": "privacyPolicyUrl",
}
VERSION_FIELDS = {
    "description": "description",
    "keywords": "keywords",
    "promotional_text": "promotionalText",
    "support_url": "supportUrl",
    "marketing_url": "marketingUrl",
}

# Apple accepts several resolutions for some display wells. Keeping the exact
# allow-list here catches an accidentally captured smaller simulator before it
# can replace a valid storefront set.
SCREENSHOT_SIZES: dict[str, set[tuple[int, int]]] = {
    # Apple's API still names the largest iPhone screenshot well "67",
    # although App Store Connect presents these current sizes as 6.9-inch.
    "APP_IPHONE_67": {
        (1260, 2736),
        (1290, 2796),
        (1320, 2868),
        (2736, 1260),
        (2796, 1290),
        (2868, 1320),
    },
    "APP_IPAD_PRO_3GEN_129": {
        (2064, 2752),
        (2048, 2732),
        (2752, 2064),
        (2732, 2048),
    },
}
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}

#: Versions that are finished with: on sale, superseded, or taken down. They
#: never stand in the way of creating the next one.
SETTLED_STATES = {
    "READY_FOR_SALE",
    "REPLACED_WITH_NEW_VERSION",
    "REMOVED_FROM_SALE",
    "DEVELOPER_REMOVED_FROM_SALE",
}


class Failure(Exception):
    """A validation or API failure that should be printed without a traceback."""


class AppStoreConnectFailure(Failure):
    """An App Store Connect response whose structured errors callers may inspect."""

    def __init__(self, method: str, path: str, status: int, response_text: str):
        super().__init__(f"{method} {path} -> {status}: {response_text}")
        self.status = status
        try:
            payload = json.loads(response_text)
        except json.JSONDecodeError:
            payload = {}
        self.errors = payload.get("errors", []) if isinstance(payload, dict) else []

    def rejects_attribute(self, attribute: str) -> bool:
        detail = f"Attribute '{attribute}' cannot be edited"
        return any(error.get("code") == "STATE_ERROR" and detail in error.get("detail", "") for error in self.errors)


@dataclass(frozen=True)
class ImageDetails:
    width: int
    height: int
    has_alpha: bool


@dataclass(frozen=True)
class LocaleListing:
    locale: str
    fields: dict[str, str]
    screenshots: dict[str, tuple[Path, ...]]


@dataclass(frozen=True)
class Listing:
    config: dict[str, str]
    locales: tuple[LocaleListing, ...]
    review_notes: str


def text_file(path: Path, *, required: bool = True) -> str:
    if not path.is_file():
        if required:
            raise Failure(f"missing {path.relative_to(REPOSITORY)}")
        return ""
    value = path.read_text(encoding="utf-8").strip()
    if required and not value:
        raise Failure(f"{path.relative_to(REPOSITORY)} is empty")
    return value


def png_details(path: Path) -> ImageDetails:
    data = path.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise Failure(f"{path.relative_to(REPOSITORY)} is not a valid PNG")
    width, height = struct.unpack(">II", data[16:24])
    colour_type = data[25]
    # Greyscale/RGB files can also gain transparency through a tRNS chunk.
    has_alpha = colour_type in (4, 6) or b"tRNS" in data[33:]
    return ImageDetails(width, height, has_alpha)


def jpeg_details(path: Path) -> ImageDetails:
    data = path.read_bytes()
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        raise Failure(f"{path.relative_to(REPOSITORY)} is not a valid JPEG")
    offset = 2
    start_of_frame = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    while offset + 4 <= len(data):
        if data[offset] != 0xFF:
            offset += 1
            continue
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            break
        marker = data[offset]
        offset += 1
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            break
        length = struct.unpack(">H", data[offset : offset + 2])[0]
        if marker in start_of_frame and offset + 7 <= len(data):
            height, width = struct.unpack(">HH", data[offset + 3 : offset + 7])
            return ImageDetails(width, height, False)
        if length < 2:
            break
        offset += length
    raise Failure(f"could not read dimensions from {path.relative_to(REPOSITORY)}")


def image_details(path: Path) -> ImageDetails:
    return png_details(path) if path.suffix.lower() == ".png" else jpeg_details(path)


def screenshot_files(directory: Path) -> tuple[Path, ...]:
    if not directory.is_dir():
        return ()
    return tuple(
        sorted(
            path for path in directory.iterdir() if path.is_file() and path.suffix.lower() in (".png", ".jpg", ".jpeg")
        )
    )


def load_listing(root: Path = STORE_ROOT) -> Listing:
    try:
        config = json.loads((root / "config.json").read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise Failure(f"missing {root / 'config.json'}") from error
    except json.JSONDecodeError as error:
        raise Failure(f"invalid app-store/config.json: {error}") from error

    for key in ("bundleId", "platform", "primaryLocale", "copyright", "releaseType"):
        if not isinstance(config.get(key), str) or not config[key].strip():
            raise Failure(f"app-store/config.json needs a non-empty {key!r}")

    metadata_root = root / "metadata"
    locale_directories = sorted(path for path in metadata_root.iterdir() if path.is_dir())
    if not locale_directories:
        raise Failure("app-store/metadata has no locale directories")

    locales: list[LocaleListing] = []
    for directory in locale_directories:
        locale = directory.name
        fields = {field: text_file(directory / f"{field}.txt") for field in REQUIRED_FIELDS}
        marketing_url = text_file(directory / "marketing_url.txt", required=False)
        if marketing_url:
            fields["marketing_url"] = marketing_url
        # What testers read on the TestFlight invitation. Optional: a locale
        # without one keeps whatever App Store Connect already has.
        beta_description = text_file(directory / "beta_description.txt", required=False)
        if beta_description:
            fields["beta_description"] = beta_description

        locale_screenshots: dict[str, tuple[Path, ...]] = {}
        screenshot_root = root / "screenshots" / locale
        if screenshot_root.is_dir():
            for display_directory in sorted(path for path in screenshot_root.iterdir() if path.is_dir()):
                files = screenshot_files(display_directory)
                if files:
                    locale_screenshots[display_directory.name] = files
        locales.append(LocaleListing(locale, fields, locale_screenshots))

    return Listing(
        config={key: str(value) for key, value in config.items()},
        locales=tuple(locales),
        review_notes=text_file(root / "review_notes.txt"),
    )


def validate_url(field: str, value: str, locale: str) -> None:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise Failure(f"{locale}/{field}.txt must be a public https URL")


def validate_listing(listing: Listing) -> list[str]:
    warnings: list[str] = []
    locales = {locale.locale for locale in listing.locales}
    if listing.config["primaryLocale"] not in locales:
        raise Failure("config primaryLocale has no matching metadata directory")

    for locale in listing.locales:
        for field, limit in FIELD_LIMITS.items():
            value = listing.review_notes if field == "review_notes" else locale.fields.get(field)
            if value is not None and len(value) > limit:
                raise Failure(f"{locale.locale}/{field} is {len(value)} characters; Apple allows {limit}")
        if " " in locale.fields["keywords"]:
            warnings.append(f"{locale.locale}/keywords contains spaces; Apple counts them in the 100-character limit")
        validate_url("support_url", locale.fields["support_url"], locale.locale)
        validate_url("privacy_policy_url", locale.fields["privacy_policy_url"], locale.locale)
        if "marketing_url" in locale.fields:
            validate_url("marketing_url", locale.fields["marketing_url"], locale.locale)

        if not locale.screenshots:
            warnings.append(f"{locale.locale} has no screenshots yet; remote screenshot sets will be left alone")
            continue
        for display_type, paths in locale.screenshots.items():
            if display_type not in SCREENSHOT_SIZES:
                raise Failure(f"unknown screenshot display directory {display_type!r}")
            if len(paths) > 10:
                raise Failure(f"{locale.locale}/{display_type} has {len(paths)} screenshots; Apple allows 10")
            dimensions: set[tuple[int, int]] = set()
            for path in paths:
                details = image_details(path)
                dimensions.add((details.width, details.height))
                if details.has_alpha:
                    raise Failure(f"{path.relative_to(REPOSITORY)} has transparency; Apple rejects alpha channels")
                if (details.width, details.height) not in SCREENSHOT_SIZES[display_type]:
                    allowed = ", ".join(f"{w}x{h}" for w, h in sorted(SCREENSHOT_SIZES[display_type]))
                    raise Failure(
                        f"{path.relative_to(REPOSITORY)} is {details.width}x{details.height}; "
                        f"{display_type} accepts {allowed}"
                    )
            if len(dimensions) != 1:
                raise Failure(f"{locale.locale}/{display_type} mixes screenshot dimensions: {sorted(dimensions)}")
    return warnings


def latest_changelog_entry(path: Path) -> tuple[str, str]:
    text = path.read_text(encoding="utf-8")
    sections = re.split(r"^## +(.+?) *$", text, flags=re.MULTILINE)
    if len(sections) < 3:
        raise Failure(f"{path} has no '## <version>' section")
    version, body = sections[1].strip(), sections[2].strip()
    if not body:
        raise Failure(f"the '## {version}' section in {path} is empty")
    if len(body) > FIELD_LIMITS["whats_new"]:
        raise Failure(f"the latest changelog entry is longer than {FIELD_LIMITS['whats_new']} characters")
    return version, body


@dataclass(frozen=True)
class SigningKey:
    key_id: str
    private_key: str
    #: None for an individual key, which belongs to a person rather than the
    #: team and has no issuer.
    issuer_id: str | None

    def claims(self, now: int) -> dict[str, Any]:
        # Apple rejects tokens with a lifetime over 20 minutes.
        claims: dict[str, Any] = {"iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
        if self.issuer_id is None:
            claims["sub"] = "user"
        else:
            claims["iss"] = self.issuer_id
        return claims


def signing_key(environ: Mapping[str, str] = os.environ) -> SigningKey:
    """The key to sign requests with.

    An individual key is preferred when one is configured: what it submits
    shows in App Store Connect under the person's name rather than as
    "API user <key id>". The team key is the fallback, and the one the build
    upload keeps using either way.
    """
    if environ.get("ASC_INDIVIDUAL_KEY_ID") and environ.get("ASC_INDIVIDUAL_KEY_P8_BASE64"):
        return SigningKey(
            environ["ASC_INDIVIDUAL_KEY_ID"],
            decode_private_key(environ["ASC_INDIVIDUAL_KEY_P8_BASE64"], "ASC_INDIVIDUAL_KEY_P8_BASE64"),
            None,
        )
    for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8_BASE64"):
        if not environ.get(name):
            raise Failure(f"{name} is not set")
    return SigningKey(
        environ["ASC_KEY_ID"],
        decode_private_key(environ["ASC_KEY_P8_BASE64"], "ASC_KEY_P8_BASE64"),
        environ["ASC_ISSUER_ID"],
    )


def decode_private_key(encoded: str, name: str) -> str:
    try:
        return base64.b64decode(encoded, validate=True).decode()
    except (ValueError, UnicodeDecodeError) as error:
        raise Failure(f"{name} is not a base64-encoded UTF-8 private key") from error


def api_token() -> str:
    import jwt

    key = signing_key()
    return jwt.encode(
        key.claims(int(time.time())),
        key.private_key,
        algorithm="ES256",
        headers={"kid": key.key_id, "typ": "JWT"},
    )


#: Answers App Store Connect gives now and then to a request that is fine:
#: a 401 for a token it accepted a moment ago, a 429, or a gateway error.
#: Retried for reads and idempotent writes. A POST is retried only when the
#: request was never accepted (401 and 429), so nothing is created twice.
TRANSIENT_STATUSES = {401, 429, 500, 502, 503, 504}
POST_RETRY_STATUSES = {401, 429}
RETRY_ATTEMPTS = 3
RETRY_DELAY_SECONDS = 5.0


class Client:
    def __init__(self, session: Any | None = None, *, sleep: Any = time.sleep) -> None:
        import requests

        self.requests = requests
        self.sleep = sleep
        self.session = session if session is not None else requests.Session()
        self.session.headers["Authorization"] = f"Bearer {api_token()}"

    def request(self, method: str, path: str, *, allow_not_found: bool = False, **kwargs: Any) -> dict:
        retryable = POST_RETRY_STATUSES if method == "POST" else TRANSIENT_STATUSES
        for attempt in range(1, RETRY_ATTEMPTS + 1):
            response = self.session.request(method, f"{API}{path}", timeout=60, **kwargs)
            if response.status_code not in retryable or attempt == RETRY_ATTEMPTS:
                break
            print(
                f"{method} {path} -> {response.status_code}; retrying ({attempt}/{RETRY_ATTEMPTS})",
                file=sys.stderr,
            )
            self.sleep(RETRY_DELAY_SECONDS * attempt)
            if response.status_code == 401:
                # A fresh token costs nothing and rules out the one thing
                # about the old one that could actually have gone wrong.
                self.session.headers["Authorization"] = f"Bearer {api_token()}"
        if allow_not_found and response.status_code == 404:
            return {}
        if not response.ok:
            raise AppStoreConnectFailure(method, path, response.status_code, response.text)
        return response.json() if response.content else {}

    def get(self, path: str, **kwargs: Any) -> dict:
        return self.request("GET", path, **kwargs)

    def post(self, path: str, body: dict) -> dict:
        return self.request("POST", path, json=body)

    def patch(self, path: str, body: dict) -> dict:
        return self.request("PATCH", path, json=body)

    def delete(self, path: str) -> None:
        self.request("DELETE", path)

    def upload_operation(self, operation: dict, data: bytes) -> None:
        offset = int(operation["offset"])
        length = int(operation["length"])
        headers = {header["name"]: header["value"] for header in operation.get("requestHeaders", [])}
        response = self.requests.request(
            operation.get("method", "PUT"),
            operation["url"],
            headers=headers,
            data=data[offset : offset + length],
            timeout=120,
        )
        if not response.ok:
            raise Failure(f"asset upload -> {response.status_code}: {response.text}")


def changed(remote: dict, desired: dict) -> bool:
    attributes = remote.get("attributes", {})
    return any(attributes.get(key) != value for key, value in desired.items())


def app_id(client: Client, bundle_id: str) -> str:
    apps = client.get("/apps", params={"filter[bundleId]": bundle_id})["data"]
    if not apps:
        raise Failure(f"no App Store Connect app found for bundle id {bundle_id}")
    if len(apps) > 1:
        raise Failure(f"more than one App Store Connect app has bundle id {bundle_id}")
    return apps[0]["id"]


def sync_app_info(client: Client, app: str, listing: Listing, dry_run: bool) -> None:
    infos = client.get(f"/apps/{app}/appInfos", params={"limit": 200})["data"]
    if not infos:
        raise Failure("the app has no appInfo resource")
    info = next((item for item in infos if item["attributes"].get("appStoreState") in EDITABLE_STATES), infos[0])
    localizations = client.get(f"/appInfos/{info['id']}/appInfoLocalizations", params={"limit": 200})["data"]
    existing = {item["attributes"]["locale"]: item for item in localizations}

    for locale in listing.locales:
        desired = {api_name: locale.fields[file_name] for file_name, api_name in APP_INFO_FIELDS.items()}
        remote = existing.get(locale.locale)
        if remote is not None and not changed(remote, desired):
            print(f"app info {locale.locale}: unchanged")
            continue
        action = "create" if remote is None else "update"
        print(f"app info {locale.locale}: {action}")
        if dry_run:
            continue
        if remote is None:
            client.post(
                "/appInfoLocalizations",
                {
                    "data": {
                        "type": "appInfoLocalizations",
                        "attributes": {"locale": locale.locale, **desired},
                        "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info["id"]}}},
                    }
                },
            )
        else:
            client.patch(
                f"/appInfoLocalizations/{remote['id']}",
                {"data": {"type": "appInfoLocalizations", "id": remote["id"], "attributes": desired}},
            )


def ensure_version(client: Client, app: str, listing: Listing, version: str, dry_run: bool) -> dict | None:
    config = listing.config
    versions = client.get(
        f"/apps/{app}/appStoreVersions",
        params={"filter[platform]": config["platform"], "limit": 200},
    )["data"]
    remote = next((item for item in versions if item["attributes"].get("versionString") == version), None)
    desired = {
        "versionString": version,
        "copyright": config["copyright"],
        "releaseType": config["releaseType"],
    }
    if remote is not None:
        state = remote["attributes"].get("appStoreState")
        if state not in EDITABLE_STATES:
            raise Failure(f"App Store version {version} is {state} and cannot be synchronised")
        if changed(remote, desired):
            print(f"version {version}: update version settings")
            if not dry_run:
                client.patch(
                    f"/appStoreVersions/{remote['id']}",
                    {"data": {"type": "appStoreVersions", "id": remote["id"], "attributes": desired}},
                )
        else:
            print(f"version {version}: unchanged")
        return remote

    editable = [item for item in versions if item["attributes"].get("appStoreState") in EDITABLE_STATES]
    if editable:
        labels = ", ".join(
            f"{item['attributes'].get('versionString')} ({item['attributes'].get('appStoreState')})"
            for item in editable
        )
        if len(editable) != 1 or editable[0]["attributes"].get("appStoreState") != "PREPARE_FOR_SUBMISSION":
            raise Failure(f"cannot create version {version}; editable App Store version(s) already exist: {labels}")

        remote = editable[0]
        build_response = client.get(f"/appStoreVersions/{remote['id']}/build", allow_not_found=True)
        if build_response.get("data") is not None:
            raise Failure(
                f"cannot retarget App Store version {remote['attributes'].get('versionString')} to {version}; "
                "it already has a selected build"
            )

        previous = remote["attributes"].get("versionString")
        print(f"version {previous}: retarget editable draft to {version}")
        if not dry_run:
            client.patch(
                f"/appStoreVersions/{remote['id']}",
                {"data": {"type": "appStoreVersions", "id": remote["id"], "attributes": desired}},
            )
        return {
            **remote,
            "attributes": {**remote.get("attributes", {}), **desired},
        }

    print(f"version {version}: create")
    if dry_run:
        return None
    try:
        return client.post(
            "/appStoreVersions",
            {
                "data": {
                    "type": "appStoreVersions",
                    "attributes": {
                        "platform": config["platform"],
                        "versionString": version,
                        **desired,
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": app}}},
                }
            },
        )["data"]
    except AppStoreConnectFailure as error:
        if error.status != 409:
            raise
        # Apple's own message is "You cannot create a new version of the App
        # in the current state", which does not say what the state is. It is
        # a version waiting for review, in review, or pending release.
        in_flight = [item for item in versions if item["attributes"].get("appStoreState") not in SETTLED_STATES]
        labels = ", ".join(
            f"{item['attributes'].get('versionString')} ({item['attributes'].get('appStoreState')})"
            for item in (in_flight or versions)
        )
        raise Failure(
            f"App Store Connect will not create version {version} while another version is in flight: {labels}. "
            "Let it be reviewed and released, or remove it from review in App Store Connect, then sync again with "
            f"'gh workflow run testflight.yml --ref main -f distribute_build=<build> -f sync_version={version}'"
        ) from error


def upload_screenshot(client: Client, screenshot_set: str, path: Path) -> str:
    contents = path.read_bytes()
    checksum = hashlib.md5(contents).hexdigest()  # noqa: S324 - Apple's upload protocol requires MD5.
    reservation = client.post(
        "/appScreenshots",
        {
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileName": path.name, "fileSize": len(contents)},
                "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": screenshot_set}}},
            }
        },
    )["data"]
    for operation in reservation["attributes"]["uploadOperations"]:
        client.upload_operation(operation, contents)
    screenshot_id = reservation["id"]
    response = client.patch(
        f"/appScreenshots/{screenshot_id}",
        {
            "data": {
                "type": "appScreenshots",
                "id": screenshot_id,
                "attributes": {"uploaded": True, "sourceFileChecksum": checksum},
            }
        },
    )["data"]
    state = response.get("attributes", {}).get("assetDeliveryState", {}).get("state")
    if state in {"FAILED", "REJECTED"}:
        raise Failure(f"Apple rejected {path.name}: {response['attributes']['assetDeliveryState']}")
    return screenshot_id


def local_screenshot_signature(paths: tuple[Path, ...]) -> list[tuple[str, str]]:
    return [(path.name, hashlib.md5(path.read_bytes()).hexdigest()) for path in paths]  # noqa: S324


def sync_screenshots(client: Client, localization: dict, locale: LocaleListing, dry_run: bool) -> None:
    sets = client.get(
        f"/appStoreVersionLocalizations/{localization['id']}/appScreenshotSets",
        params={"limit": 50},
    )["data"]
    existing = {item["attributes"]["screenshotDisplayType"]: item for item in sets}

    for display_type, paths in locale.screenshots.items():
        remote_set = existing.get(display_type)
        remote_signature: list[tuple[str, str]] = []
        if remote_set is not None:
            remote_images = client.get(f"/appScreenshotSets/{remote_set['id']}/appScreenshots", params={"limit": 50})[
                "data"
            ]
            remote_signature = [
                (image["attributes"].get("fileName", ""), image["attributes"].get("sourceFileChecksum", ""))
                for image in remote_images
            ]
        if remote_signature == local_screenshot_signature(paths):
            print(f"screenshots {locale.locale}/{display_type}: unchanged")
            continue

        print(f"screenshots {locale.locale}/{display_type}: replace with {len(paths)} image(s)")
        if dry_run:
            continue
        # All local images were opened and validated before this point. An
        # empty local directory never reaches here, so it cannot erase a set.
        if remote_set is not None:
            client.delete(f"/appScreenshotSets/{remote_set['id']}")
        screenshot_set = client.post(
            "/appScreenshotSets",
            {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": display_type},
                    "relationships": {
                        "appStoreVersionLocalization": {
                            "data": {"type": "appStoreVersionLocalizations", "id": localization["id"]}
                        }
                    },
                }
            },
        )["data"]
        ids = []
        for path in paths:
            print(f"  upload {path.name}")
            ids.append(upload_screenshot(client, screenshot_set["id"], path))
        client.patch(
            f"/appScreenshotSets/{screenshot_set['id']}/relationships/appScreenshots",
            {"data": [{"type": "appScreenshots", "id": screenshot_id} for screenshot_id in ids]},
        )


def sync_version_localizations(
    client: Client,
    version_resource: dict,
    listing: Listing,
    whats_new: str,
    dry_run: bool,
) -> None:
    version_id = version_resource["id"]
    localizations = client.get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations", params={"limit": 200})[
        "data"
    ]
    existing = {item["attributes"]["locale"]: item for item in localizations}

    for locale in listing.locales:
        desired = {
            api_name: locale.fields[file_name]
            for file_name, api_name in VERSION_FIELDS.items()
            if file_name in locale.fields
        }
        desired["whatsNew"] = whats_new
        remote = existing.get(locale.locale)
        if remote is not None and not changed(remote, desired):
            print(f"version metadata {locale.locale}: unchanged")
        else:
            action = "create" if remote is None else "update"
            print(f"version metadata {locale.locale}: {action}")
            if not dry_run:
                try:
                    remote = write_version_localization(client, version_id, locale.locale, desired, remote)
                except AppStoreConnectFailure as error:
                    # Apple does not allow What's New on an app's first public
                    # version. Keep the same changelog entry for TestFlight,
                    # and still synchronise every storefront field Apple does
                    # accept for the initial listing.
                    if not error.rejects_attribute("whatsNew"):
                        raise
                    print(f"version metadata {locale.locale}: What's New is unavailable; update remaining fields")
                    remaining = {key: value for key, value in desired.items() if key != "whatsNew"}
                    remote = write_version_localization(client, version_id, locale.locale, remaining, remote)
        if locale.screenshots:
            if dry_run and remote is None:
                print(f"screenshots {locale.locale}: would upload after creating localization")
            elif remote is not None:
                sync_screenshots(client, remote, locale, dry_run)


def write_version_localization(
    client: Client,
    version_id: str,
    locale: str,
    desired: dict[str, str],
    remote: dict | None,
) -> dict:
    if remote is None:
        return client.post(
            "/appStoreVersionLocalizations",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": {"locale": locale, **desired},
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}},
                }
            },
        )["data"]
    client.patch(
        f"/appStoreVersionLocalizations/{remote['id']}",
        {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": remote["id"],
                "attributes": desired,
            }
        },
    )
    return remote


REVIEW_CONTACT_FIELDS = {
    "contactFirstName": "ASC_REVIEW_CONTACT_FIRST_NAME",
    "contactLastName": "ASC_REVIEW_CONTACT_LAST_NAME",
    "contactEmail": "ASC_REVIEW_CONTACT_EMAIL",
    "contactPhone": "ASC_REVIEW_CONTACT_PHONE",
}


def review_contact_configured(environ: Mapping[str, str] = os.environ) -> bool:
    return all(environ.get(name) for name in REVIEW_CONTACT_FIELDS.values())


def review_details(listing: Listing, environ: Mapping[str, str] = os.environ) -> dict[str, Any]:
    """The private review record: who to ring, and the notes. Shared by App
    Review and Beta App Review, which ask the same questions."""
    missing = [environment for environment in REVIEW_CONTACT_FIELDS.values() if not environ.get(environment)]
    if missing:
        raise Failure(f"--review-notes requires {', '.join(missing)}")
    desired: dict[str, Any] = {api: environ[environment] for api, environment in REVIEW_CONTACT_FIELDS.items()}
    desired.update({"demoAccountRequired": False, "notes": listing.review_notes})
    return desired


def sync_review_notes(client: Client, version: dict, listing: Listing, dry_run: bool) -> None:
    desired = review_details(listing)
    response = client.request("GET", f"/appStoreVersions/{version['id']}/appStoreReviewDetail", allow_not_found=True)
    remote = response.get("data")
    if remote is not None and not changed(remote, desired):
        print("review details: unchanged")
        return
    print(f"review details: {'create' if remote is None else 'update'}")
    if dry_run:
        return
    if remote is None:
        client.post(
            "/appStoreReviewDetails",
            {
                "data": {
                    "type": "appStoreReviewDetails",
                    "attributes": desired,
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}},
                }
            },
        )
    else:
        client.patch(
            f"/appStoreReviewDetails/{remote['id']}",
            {"data": {"type": "appStoreReviewDetails", "id": remote["id"], "attributes": desired}},
        )


def sync_beta_descriptions(client: Client, app: str, listing: Listing, dry_run: bool) -> None:
    """The Beta App Description testers read on the TestFlight invitation,
    one per locale that keeps a beta_description.txt."""
    wanted = {
        locale.locale: locale.fields["beta_description"]
        for locale in listing.locales
        if "beta_description" in locale.fields
    }
    if not wanted:
        print("beta description: none kept in the repository; TestFlight left alone")
        return
    remotes = client.get(f"/apps/{app}/betaAppLocalizations", params={"limit": 200})["data"]
    by_locale = {item["attributes"].get("locale"): item for item in remotes}
    for locale, description in wanted.items():
        remote = by_locale.get(locale)
        desired = {"description": description}
        if remote is not None and not changed(remote, desired):
            print(f"beta description {locale}: unchanged")
            continue
        print(f"beta description {locale}: {'create' if remote is None else 'update'}")
        if dry_run:
            continue
        if remote is None:
            client.post(
                "/betaAppLocalizations",
                {
                    "data": {
                        "type": "betaAppLocalizations",
                        "attributes": {**desired, "locale": locale},
                        "relationships": {"app": {"data": {"type": "apps", "id": app}}},
                    }
                },
            )
        else:
            client.patch(
                f"/betaAppLocalizations/{remote['id']}",
                {"data": {"type": "betaAppLocalizations", "id": remote["id"], "attributes": desired}},
            )


def sync_beta_review_details(client: Client, app: str, listing: Listing, dry_run: bool) -> None:
    """Beta App Review Information: the same contact and notes App Review
    gets, on the record App Store Connect keeps for the app's TestFlight
    builds. Apple creates that record with the app, so it is only updated."""
    desired = review_details(listing)
    remote = client.get(f"/apps/{app}/betaAppReviewDetail").get("data")
    if remote is None:
        raise Failure("App Store Connect has no Beta App Review record for this app yet; open TestFlight once")
    if not changed(remote, desired):
        print("beta review details: unchanged")
        return
    print("beta review details: update")
    if dry_run:
        return
    client.patch(
        f"/betaAppReviewDetails/{remote['id']}",
        {"data": {"type": "betaAppReviewDetails", "id": remote["id"], "attributes": desired}},
    )


def status_report(client: Client, app: str, platform: str, *, recent_builds: int = 5) -> list[str]:
    """What App Store Connect believes, as the API reports it: every version
    and its state, the review submissions and theirs, the newest builds with
    where each stands in beta review, and which builds each beta group can
    see. The web page shows the same things with friendlier words, and now
    and then different ones."""
    lines: list[str] = []

    versions = client.get(f"/apps/{app}/appStoreVersions", params={"filter[platform]": platform, "limit": 200})["data"]
    lines.append("App Store versions:")
    if not versions:
        lines.append("  none")
    for version in versions:
        attributes = version["attributes"]
        state = attributes.get("appStoreState")
        line = f"  {attributes.get('versionString')}: {state}"
        if state not in SETTLED_STATES:
            build = client.get(f"/appStoreVersions/{version['id']}/build", allow_not_found=True).get("data")
            line += f", build {build['attributes'].get('version')}" if build else ", no build selected"
        lines.append(line)

    submissions = client.get(
        "/reviewSubmissions", params={"filter[app]": app, "filter[platform]": platform, "limit": 10}
    )["data"]
    lines.append("Review submissions:")
    if not submissions:
        lines.append("  none")
    for submission in submissions:
        attributes = submission["attributes"]
        lines.append(f"  {attributes.get('submittedDate') or 'not yet submitted'}: {attributes.get('state')}")

    builds = client.get(
        "/builds",
        params={
            "filter[app]": app,
            "sort": "-uploadedDate",
            "limit": recent_builds,
            "include": "preReleaseVersion",
        },
    )
    marketing = {
        item["id"]: item["attributes"].get("version")
        for item in builds.get("included", [])
        if item.get("type") == "preReleaseVersions"
    }
    lines.append("Recent builds:")
    if not builds["data"]:
        lines.append("  none")
    for build in builds["data"]:
        attributes = build["attributes"]
        release = build.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}
        marketing_version = marketing.get(release.get("id"), "?")
        line = f"  {marketing_version} ({attributes.get('version')}): {attributes.get('processingState')}"
        if attributes.get("expired"):
            line += ", expired"
        review = client.get(f"/builds/{build['id']}/betaAppReviewSubmission", allow_not_found=True).get("data")
        if review:
            line += f", beta review {review['attributes'].get('betaReviewState')}"
        else:
            line += ", not sent for beta review"
        lines.append(line)

    groups = client.get("/betaGroups", params={"filter[app]": app, "limit": 50})["data"]
    lines.append("Beta groups:")
    if not groups:
        lines.append("  none")
    for group in groups:
        attributes = group["attributes"]
        kind = "internal" if attributes.get("isInternalGroup") else "external"
        testers = client.get(f"/betaGroups/{group['id']}/betaTesters", params={"limit": 1})
        tester_count = testers.get("meta", {}).get("paging", {}).get("total", "?")
        line = f"  {attributes.get('name')} ({kind}, {tester_count} testers)"
        if attributes.get("hasAccessToAllBuilds"):
            line += ": every build automatically"
        else:
            group_builds = client.get(f"/betaGroups/{group['id']}/builds", params={"limit": recent_builds})["data"]
            numbers = ", ".join(str(item["attributes"].get("version")) for item in group_builds) or "none"
            line += f": builds {numbers}"
        lines.append(line)
    return lines


def status_command() -> int:
    listing = load_listing()
    client = Client()
    app = app_id(client, listing.config["bundleId"])
    for line in status_report(client, app, listing.config["platform"]):
        print(line)
    return 0


def validate_command() -> int:
    listing = load_listing()
    warnings = validate_listing(listing)
    screenshot_count = sum(len(paths) for locale in listing.locales for paths in locale.screenshots.values())
    print(f"App Store listing is valid: {len(listing.locales)} locale(s), {screenshot_count} screenshot(s)")
    for warning in warnings:
        print(f"warning: {warning}")
    return 0


def sync_command(args: argparse.Namespace) -> int:
    listing = load_listing()
    for warning in validate_listing(listing):
        print(f"warning: {warning}")
    changelog_version, whats_new = latest_changelog_entry(REPOSITORY / args.changelog)
    if changelog_version != args.version:
        raise Failure(f"syncing version {args.version}, but {args.changelog} has '## {changelog_version}' at the top")

    client = Client()
    app = app_id(client, listing.config["bundleId"])
    sync_app_info(client, app, listing, args.dry_run)
    version = ensure_version(client, app, listing, args.version, args.dry_run)
    if version is None:
        print("version metadata: would sync after creating the version")
        return 0
    sync_version_localizations(client, version, listing, whats_new, args.dry_run)
    if args.review_notes:
        sync_review_notes(client, version, listing, args.dry_run)
    print("dry run complete; App Store Connect was not changed" if args.dry_run else "App Store listing is in sync")
    return 0


def testflight_command(args: argparse.Namespace) -> int:
    """TestFlight's test information is app-level and idempotent, so it is
    synced on every distributed build rather than only on a release tag."""
    listing = load_listing()
    for warning in validate_listing(listing):
        print(f"warning: {warning}")
    client = Client()
    app = app_id(client, listing.config["bundleId"])
    sync_beta_descriptions(client, app, listing, args.dry_run)
    if args.review_notes:
        sync_beta_review_details(client, app, listing, args.dry_run)
    print("dry run complete; TestFlight was not changed" if args.dry_run else "TestFlight test information is in sync")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate", help="validate repository metadata and screenshots without network access")
    sync_parser = subparsers.add_parser("sync", help="write repository metadata and screenshots to App Store Connect")
    sync_parser.add_argument("--version", required=True, help="App Store version string, for example 1.0")
    sync_parser.add_argument("--changelog", default="docs/CHANGELOG.md")
    sync_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="read remote state and print changes without writing",
    )
    sync_parser.add_argument("--review-notes", action="store_true", help="also sync private App Review details")
    subparsers.add_parser(
        "status", help="print every version, review submission and recent build as the API sees them"
    )
    testflight_parser = subparsers.add_parser(
        "testflight", help="write the beta app description, and optionally Beta App Review details, to TestFlight"
    )
    testflight_parser.add_argument(
        "--dry-run", action="store_true", help="read remote state and print changes without writing"
    )
    testflight_parser.add_argument(
        "--review-notes", action="store_true", help="also sync the private Beta App Review contact and notes"
    )
    args = parser.parse_args()

    try:
        if args.command == "validate":
            return validate_command()
        if args.command == "status":
            return status_command()
        if args.command == "testflight":
            return testflight_command(args)
        return sync_command(args)
    except (Failure, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
