"""Private, short-lived PDF cache and one bounded render process at a time."""

import asyncio
import contextlib
import hashlib
import json
import logging
import os
import re
import sys
import tempfile
import time
from collections import OrderedDict
from dataclasses import asdict, dataclass
from html import escape
from pathlib import Path

from audioreader.exports import assets

logger = logging.getLogger(__name__)
# Bump for template, font or converter changes. No generated PDFs go into the DB.
EXPORT_VERSION = "1-typst-0.15.0"
MAX_PDF_BYTES = 32 * 1024 * 1024
RENDER_TIMEOUT_SECONDS = 20


@dataclass(frozen=True)
class Article:
    owner: str
    episode_id: int
    content_id: int | None
    title: str
    html: str
    text: str
    link: str | None = None
    author: str | None = None
    publication: str | None = None
    published: str | None = None


class ExportError(Exception):
    """Only these safe messages reach the client; never Typst diagnostics."""


class ExportBusy(ExportError):
    pass


def filename(title: str) -> str:
    stem = re.sub(r"[^\w .-]", "", title, flags=re.UNICODE).strip(" .")[:100].strip(" .")
    return (stem or "Article") + ".pdf"


async def render(root: Path) -> tuple[bytes, int]:
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-m",
        "audioreader.exports.worker",
        str(root),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
        env=os.environ | {"RAYON_NUM_THREADS": "1"},
    )
    try:
        async with asyncio.timeout(RENDER_TIMEOUT_SECONDS):
            stdout, _ = await process.communicate()
        if process.returncode != 0:
            raise ExportError("This article couldn’t be exported as a PDF. Please try again.")
        output = root / "article.pdf"
        if not output.is_file() or output.stat().st_size > MAX_PDF_BYTES:
            raise ExportError("This article is too large to export as a PDF.")
        data = await asyncio.to_thread(output.read_bytes)
        if not data.startswith(b"%PDF-"):
            raise ExportError("The PDF could not be prepared. Please try again.")
        metadata = json.loads(stdout)
        return data, int(metadata.get("warnings", 0))
    except TimeoutError as exc:
        raise ExportError("PDF preparation took too long. Please try again.") from exc
    finally:
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                process.kill()
            await process.wait()


class Exporter:
    """Per API process. The deployment currently runs one Uvicorn process.

    Cache identity includes the account even when the source episode is public.
    Authorization and content-version checks happen before every invocation.
    """

    def __init__(self, *, cache_bytes: int = 64 * 1024 * 1024, cache_seconds: float = 600) -> None:
        self._slot = asyncio.Semaphore(1)
        self._waiting = 0
        self._cache: OrderedDict[str, tuple[float, bytes]] = OrderedDict()
        self._bytes = 0
        self._max_bytes = cache_bytes
        self._cache_seconds = cache_seconds

    def _cached(self, key: str) -> bytes | None:
        now = time.monotonic()
        for expired in [k for k, (until, _) in self._cache.items() if until <= now]:
            self._bytes -= len(self._cache.pop(expired)[1])
        if entry := self._cache.get(key):
            self._cache.move_to_end(key)
            return entry[1]
        return None

    async def pdf(self, article: Article) -> bytes:
        if not article.text.strip():
            raise ExportError("This article has no readable text to export yet.")
        if len(article.html.encode()) > assets.MAX_HTML_BYTES or len(article.text.encode()) > assets.MAX_HTML_BYTES:
            raise ExportError("This article is too large to export as a PDF.")
        serialized = json.dumps(asdict(article), ensure_ascii=False)
        key = hashlib.sha256((EXPORT_VERSION + serialized).encode()).hexdigest()
        if cached := self._cached(key):
            return cached
        if self._waiting >= 4:
            raise ExportBusy("PDF export is busy. Please try again in a moment.")
        self._waiting += 1
        try:
            async with asyncio.timeout(5):
                await self._slot.acquire()
        except TimeoutError as exc:
            raise ExportBusy("PDF export is busy. Please try again in a moment.") from exc
        finally:
            self._waiting -= 1
        try:
            # Coalesce repeated requests that waited for the same export.
            if cached := self._cached(key):
                return cached
            started = time.monotonic()
            with tempfile.TemporaryDirectory(prefix="magpie-export-") as folder:
                root = Path(folder)
                source = (
                    article.html
                    if article.html.strip()
                    else "".join(f"<p>{escape(line)}</p>" for line in article.text.splitlines() if line.strip())
                )
                downloads = await assets.fetch(source, article.link or "", root)
                payload = asdict(article) | {"html": source, "downloads": downloads}
                await asyncio.to_thread((root / "input.json").write_text, json.dumps(payload, ensure_ascii=False))
                data, warning_count = await render(root)
            if len(data) <= self._max_bytes:
                while self._cache and self._bytes + len(data) > self._max_bytes:
                    self._bytes -= len(self._cache.popitem(last=False)[1][1])
                self._cache[key] = (time.monotonic() + self._cache_seconds, data)
                self._bytes += len(data)
            logger.info(
                "PDF export completed: duration_ms=%.0f bytes=%d warnings=%d",
                (time.monotonic() - started) * 1000,
                len(data),
                warning_count,
            )
            return data
        except ExportError:
            raise
        except (ValueError, OSError) as exc:
            raise ExportError("This article couldn’t be exported as a PDF. Please try again.") from exc
        finally:
            self._slot.release()
