"""Explicit, bounded provider requests. Never attach credentials to result downloads."""

import json
import re
from urllib.parse import urljoin

import httpx

from audioreader.config import settings
from audioreader.feeds.fetcher import MAX_REDIRECTS, FeedFetchError, private_request, validate_public_url

API = "https://www.datalab.to/api/v1"
MAX_RESULT_BYTES = 24 * 1024 * 1024


class ConversionError(Exception):
    pass


class SubmissionUncertain(ConversionError):
    pass


def valid_request_id(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,200}", value):
        raise ConversionError("The conversion service returned an invalid receipt.")
    return value


async def request(method: str, path: str, **kwargs) -> dict:
    with private_request():
        async with httpx.AsyncClient(timeout=60, follow_redirects=False, trust_env=False) as client:
            async with client.stream(
                method, f"{API}/{path}", headers={"X-API-Key": settings.datalab_api_key}, **kwargs
            ) as response:
                response.raise_for_status()
                raw = bytearray()
                async for chunk in response.aiter_bytes():
                    raw.extend(chunk)
                    if len(raw) > MAX_RESULT_BYTES:
                        raise ConversionError("The converted document is too large for this beta.")
                if not raw:
                    return {}
                result = json.loads(raw)
                if not isinstance(result, dict):
                    raise ConversionError("The conversion service returned an invalid result.")
                return result


async def submit(source_url: str | None, original: bytes | None) -> str:
    data = {
        "mode": "balanced",
        "output_format": "html,json",
        "add_block_ids": "true",
        "disable_image_captions": "true",
        "max_pages": str(settings.pdf_max_pages),
    }
    files = None
    if source_url:
        data["file_url"] = source_url
    else:
        files = {"file": ("document.pdf", original, "application/pdf")}
    try:
        result = await request("POST", "convert", data=data, files=files)
        if result.get("success") is False:
            raise ConversionError("Datalab could not accept this PDF. Try sharing the downloaded file.")
        return valid_request_id(result.get("request_id"))
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code < 500:
            raise ConversionError("Datalab could not accept this PDF. Try again later.") from None
        raise SubmissionUncertain("Submission could not be confirmed. Retrying may process the PDF twice.") from None
    except (httpx.HTTPError, ValueError) as exc:
        raise SubmissionUncertain("Submission could not be confirmed. Retrying may process the PDF twice.") from exc


async def poll(request_id: str) -> dict:
    result = await request("GET", f"convert/{valid_request_id(request_id)}")
    if result.get("status") != "complete" or not result.get("result_url"):
        return result
    url = result["result_url"]
    # Result URLs can contain credentials and use another storage host. No API key follows them.
    with private_request():
        async with httpx.AsyncClient(timeout=60, follow_redirects=False, trust_env=False) as client:
            for _ in range(MAX_REDIRECTS + 1):
                await validate_public_url(url)
                async with client.stream("GET", url) as response:
                    if response.is_redirect:
                        url = urljoin(url, response.headers.get("location", ""))
                        continue
                    response.raise_for_status()
                    raw = bytearray()
                    async for chunk in response.aiter_bytes():
                        raw.extend(chunk)
                        if len(raw) > MAX_RESULT_BYTES:
                            raise ConversionError("The converted document is too large for this beta.")
                    downloaded = json.loads(raw)
                    if not isinstance(downloaded, dict):
                        raise ConversionError("The conversion service returned an invalid result.")
                    downloaded.update({k: v for k, v in result.items() if v is not None and k != "result_url"})
                    return downloaded
    raise FeedFetchError("Too many result redirects")


async def delete_result(request_id: str) -> None:
    try:
        await request("DELETE", f"results/{valid_request_id(request_id)}")
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code not in {404, 410}:
            raise
